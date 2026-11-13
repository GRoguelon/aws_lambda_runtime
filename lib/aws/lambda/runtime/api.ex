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

  @extensions_api_version "2020-01-01"

  @post_timeout 15_000

  @json_headers [{"content-type", "application/json"}]

  @error_type_header "lambda-runtime-function-error-type"

  @error_body_header "lambda-runtime-function-error-body"

  # A Function URL in RESPONSE_STREAM mode reads a JSON prelude (status,
  # headers, cookies) ended by eight NUL bytes before the body.
  @http_integration_content_type "application/vnd.awslambda.http-integration-response"

  @prelude_delimiter <<0, 0, 0, 0, 0, 0, 0, 0>>

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

  @doc """
  Streams a successful result for `request_id`, sending each element of
  `chunks` to the caller as it is produced.

  ## Options

    * `:content_type` (required) - the content type of the stream.
    * `:prelude` - for a Function URL in `RESPONSE_STREAM` mode, a map with
      the `"statusCode"`, `"headers"` and `"cookies"` of the HTTP response,
      sent before the chunks. The stream is then sent as
      `#{@http_integration_content_type}`.
    * `:on_error` - function called with `kind, reason, stacktrace` if
      enumerating `chunks` fails once streaming has started; returns the
      `{error_type, payload}` to report in the trailers. Required.
    * `:send_timeout` - in milliseconds, for each chunk written.
  """
  def invocation_response_stream(request_id, chunks, opts) do
    on_error = Keyword.fetch!(opts, :on_error)

    {content_type, chunks} =
      case Keyword.get(opts, :prelude) do
        nil ->
          {Keyword.fetch!(opts, :content_type), chunks}

        prelude ->
          {@http_integration_content_type,
           Stream.concat([encode!(prelude), @prelude_delimiter], chunks)}
      end

    headers = [
      {"content-type", content_type},
      {"lambda-runtime-function-response-mode", "streaming"},
      {"trailer", "#{@error_type_header}, #{@error_body_header}"}
    ]

    trailers = fn
      :ok ->
        []

      {:error, kind, reason, stacktrace} ->
        {error_type, payload} = on_error.(kind, reason, stacktrace)

        [
          {@error_type_header, error_type},
          {@error_body_header, payload |> JSON.encode!() |> Base.encode64()}
        ]
    end

    path = versioned("/runtime/invocation/#{request_id}/response")

    api_endpoint()
    |> HTTP.stream_request("POST", path, headers, chunks,
      timeout: @post_timeout,
      send_timeout: Keyword.get(opts, :send_timeout, 30_000),
      trailers: trailers
    )
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

  @doc """
  Registers an extension named `name` for `events` with the Extensions API,
  and returns its identifier.

  Registered from the runtime process, it is an internal extension: Lambda
  then sends the runtime a SIGTERM before shutting the execution environment
  down. Must be called during the init phase, before the first
  `next_invocation/0`.
  """
  def register_extension(name, events) do
    path = "/" <> @extensions_api_version <> "/extension/register"
    headers = [{"lambda-extension-name", name} | @json_headers]

    case HTTP.request(api_endpoint(), "POST", path, headers, encode!(%{"events" => events}),
           timeout: @post_timeout
         ) do
      {:ok, 200, headers, _body} ->
        {:ok, headers["lambda-extension-identifier"]}

      {:ok, status, _headers, body} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Long-polls `GET /extension/event/next` for the extension `id`.

  Lambda only considers an extension ready, and only sends an invocation,
  once it waits for its next event. Registered for none, the call never
  returns.
  """
  def next_extension_event(id) do
    path = "/" <> @extensions_api_version <> "/extension/event/next"

    case HTTP.request(
           api_endpoint(),
           "GET",
           path,
           [{"lambda-extension-identifier", id}],
           "",
           timeout: :infinity
         ) do
      {:ok, 200, headers, body} ->
        {:ok, headers, body}

      {:ok, status, _headers, body} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Private functions

  defp error_type_header(error_type) do
    [{@error_type_header, error_type}]
  end

  defp post(path, body, headers) do
    request("POST", path, @json_headers ++ headers, body, timeout: @post_timeout)
  end

  defp request(method, path, headers, body, opts) do
    HTTP.request(api_endpoint(), method, versioned(path), headers, body, opts)
  end

  defp versioned(path) do
    "/" <> @api_version <> path
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
