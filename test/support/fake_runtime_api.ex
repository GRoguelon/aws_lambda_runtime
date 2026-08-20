defmodule Support.FakeRuntimeAPI do
  @moduledoc """
  A minimal `:gen_tcp`-based stand-in for the AWS Lambda Runtime API.

  Kept dependency free, like the library itself: no HTTP server library is
  pulled in just to test the `:httpc` client. Each element of `steps` handles
  exactly one HTTP request/response exchange, in order; once the list is
  exhausted the listening socket is closed and further connections fail.
  """

  ## Public functions

  @doc """
  Starts the fake server and returns `{pid, endpoint}`, where `endpoint` is
  the `host:port` string expected by `AWS_LAMBDA_RUNTIME_API`.

  Each step is a function `({method, path, headers, body} -> {status,
  headers, body})`, invoked once per accepted connection.
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
    body = recv_body(socket, headers)

    {to_string(method), path, headers, body}
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
        # which never happens for a bodyless request. OTP 27's httpc sends
        # this header on GETs (OTP 28+ doesn't), so this case is reachable.
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
