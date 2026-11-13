defmodule AWS.Lambda.Runtime.HTTP do
  @moduledoc """
  Minimal HTTP/1.1 client over `:gen_tcp` for the Lambda Runtime API.

  The Runtime API is plain HTTP on a link-local address, so a small client is
  enough: one connection per request (`connection: close`), and a response
  body delimited by its `content-length`, chunked encoding or the connection
  closing. Status lines and headers are parsed by the VM's own HTTP packet
  decoder (`packet: :http_bin`), so neither `:inets` nor `:ssl` has to be
  started.
  """

  ## Types

  @type endpoint :: {host :: charlist(), :inet.port_number()}
  @type headers :: [{String.t(), String.t()}]
  @type response ::
          {:ok, status :: 100..599, headers :: %{String.t() => String.t()}, body :: binary()}

  ## Module attributes

  @connect_timeout 2_000

  ## Public functions

  @doc """
  Sends `method path` to `endpoint` and reads the whole response.

  Header names and values must be binaries; names are sent as given and
  returned lowercased.

  ## Options

    * `:connect_timeout` - in milliseconds. Defaults to `#{@connect_timeout}`.
    * `:timeout` - in milliseconds or `:infinity` (the default), for each
      read of the response. `GET /next` blocks until an invocation arrives,
      so it must be allowed to wait forever.
  """
  @spec request(endpoint(), String.t(), String.t(), headers(), iodata(), keyword()) ::
          response() | {:error, term()}
  def request({host, port}, method, path, headers, body, opts \\ []) do
    connect_timeout = Keyword.get(opts, :connect_timeout, @connect_timeout)
    timeout = Keyword.get(opts, :timeout, :infinity)

    socket_opts = [:binary, active: false, packet: :http_bin, nodelay: true]

    with {:ok, request} <- encode_request(method, path, host, port, headers, body),
         {:ok, socket} <- :gen_tcp.connect(host, port, socket_opts, connect_timeout) do
      try do
        with :ok <- :gen_tcp.send(socket, request),
             {:ok, status} <- recv_status(socket, timeout),
             {:ok, headers} <- recv_headers(socket, timeout, %{}),
             {:ok, body} <- recv_body(socket, headers, timeout) do
          {:ok, status, headers, body}
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  ## Private functions

  # Request

  defp encode_request(method, path, host, port, headers, body) do
    headers =
      [{"host", "#{host}:#{port}"}, {"connection", "close"}] ++
        content_length(method, body) ++ headers

    case Enum.find(headers, &unsafe_header?/1) do
      nil ->
        lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)

        {:ok, [method, ?\s, path, " HTTP/1.1\r\n", lines, "\r\n", body]}

      {name, _value} ->
        {:error, {:invalid_header, name}}
    end
  end

  defp content_length("GET", body) when body in ["", []] do
    []
  end

  defp content_length(_method, body) do
    [{"content-length", body |> IO.iodata_length() |> Integer.to_string()}]
  end

  # A CR or LF would let a value (e.g. an error type) inject headers.
  defp unsafe_header?({name, value}) do
    String.contains?(name, ["\r", "\n"]) or String.contains?(value, ["\r", "\n"])
  end

  # Status line and headers, parsed by the `:http_bin` packet decoder.

  defp recv_status(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, {:http_response, _version, status, _reason}} ->
        {:ok, status}

      {:ok, other} ->
        {:error, {:invalid_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_headers(socket, timeout, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, {:http_header, _index, name, _reserved, value}} ->
        recv_headers(socket, timeout, Map.put(acc, header_name(name), value))

      {:ok, :http_eoh} ->
        {:ok, acc}

      {:ok, other} ->
        {:error, {:invalid_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Well-known names come back as atoms (:"Content-Length"), others as binaries.
  defp header_name(name) when is_atom(name) do
    name |> Atom.to_string() |> String.downcase()
  end

  defp header_name(name) do
    String.downcase(name)
  end

  # Body

  defp recv_body(socket, headers, timeout) do
    cond do
      chunked?(headers) ->
        recv_chunks(socket, timeout, [])

      length = headers["content-length"] ->
        with :ok <- :inet.setopts(socket, packet: :raw) do
          recv_exactly(socket, length, timeout)
        end

      true ->
        with :ok <- :inet.setopts(socket, packet: :raw) do
          recv_until_closed(socket, timeout, [])
        end
    end
  end

  defp chunked?(headers) do
    headers
    |> Map.get("transfer-encoding", "")
    |> String.downcase()
    |> String.contains?("chunked")
  end

  defp recv_exactly(socket, length, timeout) do
    case Integer.parse(length) do
      # `recv(socket, 0)` would mean "whatever is available", not zero bytes.
      {0, ""} ->
        {:ok, ""}

      {size, ""} when size > 0 ->
        :gen_tcp.recv(socket, size, timeout)

      _invalid ->
        {:error, {:invalid_content_length, length}}
    end
  end

  defp recv_until_closed(socket, timeout, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        recv_until_closed(socket, timeout, [acc | data])

      {:error, :closed} ->
        {:ok, IO.iodata_to_binary(acc)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Chunked encoding: the Runtime Interface Emulator, a Go server, may use it
  # for bodies it doesn't announce a length for.
  defp recv_chunks(socket, timeout, acc) do
    with :ok <- :inet.setopts(socket, packet: :line),
         {:ok, line} <- :gen_tcp.recv(socket, 0, timeout),
         {:ok, size} <- chunk_size(line) do
      if size == 0 do
        with :ok <- skip_trailers(socket, timeout) do
          {:ok, IO.iodata_to_binary(acc)}
        end
      else
        with :ok <- :inet.setopts(socket, packet: :raw),
             {:ok, chunk} <- :gen_tcp.recv(socket, size, timeout),
             :ok <- recv_crlf(socket, timeout) do
          recv_chunks(socket, timeout, [acc | chunk])
        end
      end
    end
  end

  # "1a;name=value\r\n": the size is hexadecimal, extensions are ignored.
  defp chunk_size(line) do
    [size | _extensions] = String.split(line, ";", parts: 2)

    case size |> String.trim() |> Integer.parse(16) do
      {size, ""} -> {:ok, size}
      _invalid -> {:error, {:invalid_chunk_size, line}}
    end
  end

  defp recv_crlf(socket, timeout) do
    case :gen_tcp.recv(socket, 2, timeout) do
      {:ok, "\r\n"} -> :ok
      {:ok, other} -> {:error, {:invalid_chunk, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp skip_trailers(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, "\r\n"} -> :ok
      {:ok, _trailer} -> skip_trailers(socket, timeout)
      {:error, reason} -> {:error, reason}
    end
  end
end
