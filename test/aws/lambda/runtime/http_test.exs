defmodule AWS.Lambda.Runtime.HTTPTest do
  use ExUnit.Case, async: true

  alias AWS.Lambda.Runtime.HTTP

  describe "request/6" do
    test "sends the request line, host and connection headers" do
      endpoint = raw_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")

      assert {:ok, 200, %{"content-length" => "2"}, "ok"} =
               HTTP.request(endpoint, "GET", "/path", [{"x-a", "b"}], "")

      assert_receive {:request, request}, 1_000
      {_host, port} = endpoint

      assert request ==
               "GET /path HTTP/1.1\r\nhost: 127.0.0.1:#{port}\r\nconnection: close\r\n" <>
                 "x-a: b\r\n\r\n"
    end

    test "sends a content-length with a body" do
      endpoint = raw_server("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n")

      assert {:ok, 202, _headers, ""} = HTTP.request(endpoint, "POST", "/", [], ["{", "}"])

      assert_receive {:request, request}, 1_000
      assert request =~ "content-length: 2\r\n"
      assert String.ends_with?(request, "\r\n\r\n{}")
    end

    test "reads a chunked body, ignoring extensions and trailers" do
      endpoint =
        raw_server(
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" <>
            "5\r\nhello\r\n6;name=value\r\n world\r\n0\r\nTrailer: v\r\n\r\n"
        )

      assert {:ok, 200, %{"transfer-encoding" => "chunked"}, "hello world"} =
               HTTP.request(endpoint, "GET", "/", [], "")
    end

    test "reads a body delimited by the connection closing" do
      endpoint = raw_server("HTTP/1.1 200 OK\r\nX-A: b\r\n\r\nuntil close")

      assert {:ok, 200, %{"x-a" => "b"}, "until close"} =
               HTTP.request(endpoint, "GET", "/", [], "")
    end

    test "refuses header values that would inject headers" do
      assert {:error, {:invalid_header, "x"}} =
               HTTP.request({~c"127.0.0.1", 1}, "POST", "/", [{"x", "a\r\nevil: 1"}], "")
    end

    test "returns an error on a response that isn't HTTP" do
      endpoint = raw_server("garbage\r\n\r\n")

      assert {:error, {:invalid_response, _}} = HTTP.request(endpoint, "GET", "/", [], "")
    end
  end

  # Serves `response` to one connection and sends the raw request it received
  # to the test process.
  defp raw_server(response) do
    test_pid = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 5_000)
      send(test_pid, {:request, recv_request(socket, "")})
      :ok = :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end)

    {~c"127.0.0.1", port}
  end

  # Reads up to the end of the headers, plus the body its content-length announces.
  defp recv_request(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        length =
          case Regex.run(~r/content-length: (\d+)/, head) do
            [_, length] -> String.to_integer(length)
            nil -> 0
          end

        if byte_size(body) >= length,
          do: acc,
          else: recv_more(socket, acc)

      [_incomplete] ->
        recv_more(socket, acc)
    end
  end

  defp recv_more(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_request(socket, acc <> data)
      {:error, _reason} -> acc
    end
  end
end
