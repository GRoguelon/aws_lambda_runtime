defmodule Support.FakeRuntimeAPI do
  @moduledoc """
  A minimal `:gen_tcp`-based stand-in for the AWS Lambda Runtime API.

  Kept dependency free, like the library itself: no HTTP server library is
  pulled in just to test the HTTP client. Each element of `steps` handles
  exactly one HTTP request/response exchange, in order; once the list is
  exhausted the listening socket is closed and further connections fail.
  """

  ## Public functions

  @doc """
  Starts the fake server and returns `{pid, endpoint}`, where `endpoint` is
  the `host:port` string expected by `AWS_LAMBDA_RUNTIME_API`.

  Each step is a function `({method, path, headers, body} -> {status,
  headers, body})`, invoked once per accepted connection. A chunked request
  body (response streaming) is decoded, and its trailers are merged into
  `headers`.
  """
  def start(steps) when is_list(steps) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :http_bin])

    {:ok, port} = :inet.port(listen_socket)

    pid = spawn_link(fn -> serve(listen_socket, steps) end)

    {pid, "127.0.0.1:#{port}"}
  end

  ## Private functions

  defp serve(listen_socket, []) do
    :gen_tcp.close(listen_socket)
  end

  defp serve(listen_socket, [step | rest]) do
    case :gen_tcp.accept(listen_socket, 5_000) do
      {:ok, socket} ->
        request = recv_request(socket)
        {status, headers, body} = step.(request)

        send_response(socket, status, headers, body)
        :gen_tcp.close(socket)

        serve(listen_socket, rest)

      {:error, :timeout} ->
        :gen_tcp.close(listen_socket)
    end
  end

  defp recv_request(socket) do
    {:ok, {:http_request, method, {:abs_path, path}, _version}} = :gen_tcp.recv(socket, 0)

    headers = recv_headers(socket, %{})

    {headers, body} =
      if headers["transfer-encoding"] == "chunked" do
        recv_chunks(socket, headers, [])
      else
        {headers, recv_body(socket, headers)}
      end

    {to_string(method), path, headers, body}
  end

  defp recv_chunks(socket, headers, acc) do
    :ok = :inet.setopts(socket, packet: :line)
    {:ok, line} = :gen_tcp.recv(socket, 0)
    {size, _rest} = line |> String.trim() |> Integer.parse(16)

    :ok = :inet.setopts(socket, packet: :raw)

    if size == 0 do
      {recv_trailers(socket, headers, ""), IO.iodata_to_binary(acc)}
    else
      {:ok, chunk} = :gen_tcp.recv(socket, size)
      {:ok, "\r\n"} = :gen_tcp.recv(socket, 2)
      recv_chunks(socket, headers, [acc | chunk])
    end
  end

  # Read raw up to the blank line: `packet: :line` would split a trailer
  # longer than the receive buffer, such as a base64-encoded error body.
  defp recv_trailers(_socket, headers, "\r\n") do
    headers
  end

  defp recv_trailers(socket, headers, acc) do
    if String.ends_with?(acc, "\r\n\r\n") do
      acc
      |> String.split("\r\n", trim: true)
      |> Enum.reduce(headers, fn line, headers ->
        [name, value] = String.split(line, ":", parts: 2)
        Map.put(headers, String.downcase(name), String.trim(value))
      end)
    else
      {:ok, data} = :gen_tcp.recv(socket, 0)
      recv_trailers(socket, headers, acc <> data)
    end
  end

  defp recv_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _, field, _, value}} ->
        recv_headers(socket, Map.put(acc, header_name(field), value))

      {:ok, :http_eoh} ->
        :ok = :inet.setopts(socket, packet: :raw)
        acc
    end
  end

  defp header_name(field) when is_atom(field), do: field |> Atom.to_string() |> String.downcase()
  defp header_name(field) when is_binary(field), do: String.downcase(field)

  defp recv_body(socket, headers) do
    case Map.get(headers, "content-length") do
      nil ->
        ""

      "0" ->
        # `:gen_tcp.recv(socket, 0)` doesn't mean "read zero bytes": it means
        # "read whatever is available, blocking until something arrives" -
        # which never happens for a bodyless request, e.g. a POST of an empty
        # body.
        ""

      length ->
        {:ok, body} = :gen_tcp.recv(socket, String.to_integer(length))
        body
    end
  end

  defp send_response(socket, status, headers, body) do
    status_line = "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n"

    header_lines =
      headers
      |> Map.put("content-length", byte_size(body))
      |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)

    :gen_tcp.send(socket, status_line <> header_lines <> "\r\n" <> body)
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(202), do: "Accepted"
  defp reason_phrase(500), do: "Internal Server Error"
end
