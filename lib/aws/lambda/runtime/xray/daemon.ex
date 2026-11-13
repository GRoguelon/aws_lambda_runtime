defmodule AWS.Lambda.Runtime.XRay.Daemon do
  @moduledoc """
  Sends segment documents to the X-Ray daemon, over UDP.

  Lambda runs the daemon in the sandbox when the function's tracing mode is
  `Active`, and gives its address in `AWS_XRAY_DAEMON_ADDRESS`, e.g.
  `169.254.79.129:2000`. The `tcp:HOST:PORT udp:HOST:PORT` form the X-Ray
  SDKs accept is understood too; only the UDP address is used. Outside Lambda
  the daemon's default address, `127.0.0.1:2000`, is assumed.

  Each document is one datagram, opened, sent and closed on the spot: there is
  no socket to own or supervise, and nothing waits for the daemon to read it.
  """

  require Logger

  ## Module attributes

  @header ~s({"format":"json","version":1}\n)

  @default_address "127.0.0.1:2000"

  # The daemon reads datagrams of up to 64KB, header included.
  @max_size 64 * 1024

  ## Public functions

  @doc """
  Encodes `document` as JSON and sends it to the daemon.

  Never raises: a document that cannot be encoded, is too large or cannot be
  sent is dropped, with a warning, and `{:error, reason}` is returned.
  """
  @spec send_document(map()) :: :ok | {:error, term()}
  def send_document(document) when is_map(document) do
    with {:ok, datagram} <- encode(document),
         {:ok, address} <- address(),
         :ok <- send_datagram(address, datagram) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("could not send the X-Ray segment: #{inspect(reason)}")

        error
    end
  end

  ## Private functions

  defp encode(document) do
    datagram = [@header | JSON.encode_to_iodata!(document)]

    case IO.iodata_length(datagram) do
      size when size > @max_size -> {:error, {:too_large, size}}
      _size -> {:ok, datagram}
    end
  rescue
    exception -> {:error, {:unencodable, Exception.message(exception)}}
  end

  defp send_datagram({host, port}, datagram) do
    with {:ok, socket} <- :gen_udp.open(0, [:binary]) do
      result = :gen_udp.send(socket, host, port, datagram)

      :gen_udp.close(socket)

      result
    end
  end

  defp address do
    value = System.get_env("AWS_XRAY_DAEMON_ADDRESS", @default_address)

    udp =
      value
      |> String.split()
      |> Enum.find_value(value, fn
        "udp:" <> address -> address
        _other -> nil
      end)

    with [host, port] <- String.split(udp, ":", parts: 2),
         {port, ""} <- Integer.parse(port) do
      {:ok, {host(host), port}}
    else
      _invalid -> {:error, {:invalid_daemon_address, value}}
    end
  end

  # An IP address is used as is, rather than resolved on every send.
  defp host(host) do
    host = String.to_charlist(host)

    case :inet.parse_address(host) do
      {:ok, ip} -> ip
      {:error, :einval} -> host
    end
  end
end
