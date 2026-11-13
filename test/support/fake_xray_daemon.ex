defmodule Support.FakeXRayDaemon do
  @moduledoc """
  A `:gen_udp` stand-in for the X-Ray daemon, receiving segment documents in
  the test process.
  """

  import ExUnit.Assertions

  ## Public functions

  @doc """
  Opens a UDP socket and returns `{socket, address}`, where `address` is the
  `host:port` string expected by `AWS_XRAY_DAEMON_ADDRESS`.
  """
  def start do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)

    {socket, "127.0.0.1:#{port}"}
  end

  @doc """
  Receives the next datagram, asserts its header, and returns its document
  decoded.
  """
  def receive_document(socket, timeout \\ 1_000) do
    assert {:ok, {_address, _port, datagram}} = :gen_udp.recv(socket, 0, timeout)
    assert [header, body] = String.split(datagram, "\n", parts: 2)
    assert JSON.decode!(header) == %{"format" => "json", "version" => 1}

    JSON.decode!(body)
  end

  @doc "Asserts nothing is received within `timeout` milliseconds."
  def refute_document(socket, timeout \\ 100) do
    assert {:error, :timeout} = :gen_udp.recv(socket, 0, timeout)
  end
end
