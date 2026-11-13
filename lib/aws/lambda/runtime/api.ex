defmodule AWS.Lambda.Runtime.API do
  @moduledoc """
  Client for the AWS Lambda Runtime API (version `2018-06-01`), over
  `AWS.Lambda.Runtime.HTTP`.

  Deliberately dependency free: it only needs `:kernel`, so no other OTP
  application has to start before the first invocation.

  The endpoint is taken from the `AWS_LAMBDA_RUNTIME_API` environment variable
  that Lambda injects into the sandbox, e.g. `127.0.0.1:9001`.
  """

  alias AWS.Lambda.Runtime.HTTP

  ## Module attributes

  @api_version "2018-06-01"

  @post_timeout 15_000

  @json_headers [{"content-type", "application/json"}]

  @persistent_term_key {__MODULE__, :endpoint}

  ## Public functions

  @doc """
  Parses and caches the Runtime API endpoint, raising if it isn't set.
  """
  def setup do
    _endpoint = api_endpoint()

    :ok
  end

  @doc """
  Long-polls `GET /runtime/invocation/next`.

  Blocks until Lambda hands over an invocation, which is also the point at
  which the sandbox is frozen between requests. Returns the response headers
  (downcased, as a map) and the raw JSON body.
  """
  def next_invocation do
    case request("GET", "/runtime/invocation/next", [], "", timeout: :infinity) do
      {:ok, 200, headers, body} ->
        {:ok, headers, body}

      {:ok, status, _headers, body} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Posts a successful result for `request_id`."
  def invocation_response(request_id, body) do
    "/runtime/invocation/#{request_id}/response"
    |> post(body, [])
    |> expect_accepted()
  end

  @doc "Posts a handler failure for `request_id`."
  def invocation_error(request_id, %{} = payload, error_type) do
    "/runtime/invocation/#{request_id}/error"
    |> post(encode!(payload), error_type_header(error_type))
    |> expect_accepted()
  end

  @doc """
  Posts an initialisation failure.

  Lambda treats this as a fatal cold-start error and will not send any
  invocation to this sandbox.
  """
  def init_error(%{} = payload, error_type) do
    "/runtime/init/error"
    |> post(encode!(payload), error_type_header(error_type))
    |> expect_accepted()
  end

  ## Private functions

  defp error_type_header(error_type) do
    [{"lambda-runtime-function-error-type", error_type}]
  end

  defp post(path, body, headers) do
    request("POST", path, @json_headers ++ headers, body, timeout: @post_timeout)
  end

  defp request(method, path, headers, body, opts) do
    HTTP.request(api_endpoint(), method, "/" <> @api_version <> path, headers, body, opts)
  end

  defp expect_accepted({:ok, status, _headers, _body}) when status in 200..299 do
    :ok
  end

  defp expect_accepted({:ok, status, _headers, body}) do
    {:error, {:unexpected_status, status, body}}
  end

  defp expect_accepted({:error, reason}) do
    {:error, reason}
  end

  defp encode!(payload) do
    JSON.encode_to_iodata!(payload)
  end

  # `{host, port}` for :gen_tcp, parsed once from e.g. "127.0.0.1:9001".
  defp api_endpoint do
    if endpoint = :persistent_term.get(@persistent_term_key, nil) do
      endpoint
    else
      endpoint =
        System.get_env("AWS_LAMBDA_RUNTIME_API")
        |> parse_endpoint()

      :ok = :persistent_term.put(@persistent_term_key, endpoint)

      endpoint
    end
  end

  defp parse_endpoint(nil) do
    raise """
    AWS_LAMBDA_RUNTIME_API is not set.

    This process is meant to be started by the Lambda sandbox through the
    `bootstrap` script. To run it locally, point it at the AWS Lambda
    Runtime Interface Emulator (see README).
    """
  end

  defp parse_endpoint(value) do
    with [host, port] <- String.split(value, ":", parts: 2),
         {port, ""} <- Integer.parse(port) do
      {String.to_charlist(host), port}
    else
      _invalid ->
        raise "AWS_LAMBDA_RUNTIME_API must be HOST:PORT, got: #{inspect(value)}"
    end
  end
end
