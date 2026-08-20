defmodule AWS.Lambda.Runtime.API do
  @moduledoc """
  `:httpc` client for the AWS Lambda Runtime API (version `2018-06-01`).

  Deliberately dependency free: the only requirement is `:inets`, which ships
  with OTP and therefore comes from the ERTS layer at `/opt/otp`.

  The endpoint is taken from the `AWS_LAMBDA_RUNTIME_API` environment variable
  that Lambda injects into the sandbox, e.g. `127.0.0.1:9001`.
  """

  ## Module attributes

  @api_version "2018-06-01"

  @connect_timeout 2_000

  @post_timeout 15_000

  @json_content_type ~c"application/json"

  @persistent_term_key {__MODULE__, :endpoint}

  @profile :lambda_runtime

  @profile_otps [
    # One connection is all we need: the runtime is strictly sequential.
    max_sessions: 1,
    max_keep_alive_length: 1_000_000,
    # Longest possible Lambda timeout, so the socket survives a freeze.
    keep_alive_timeout: 900_000,
    max_pipeline_length: 0,
    socket_opts: [nodelay: true]
  ]

  ## Public functions

  @doc """
  Starts a dedicated `:httpc` profile and caches the Runtime API endpoint.

  A dedicated profile keeps runtime traffic isolated from whatever the handler
  does with the default profile, and lets us tune keep-alive without affecting
  user code.
  """
  def setup do
    _endpoint = api_endpoint()

    case :inets.start(:httpc, profile: @profile) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise "could not start httpc profile: #{inspect(reason)}"
    end

    :ok = :httpc.set_options(@profile_otps, @profile)
  end

  @doc """
  Long-polls `GET /runtime/invocation/next`.

  Blocks until Lambda hands over an invocation, which is also the point at
  which the sandbox is frozen between requests. Returns the response headers
  (downcased, as a map) and the raw JSON body.
  """
  def next_invocation do
    case request(:get, {path_url("/runtime/invocation/next"), []}, timeout: :infinity) do
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
    |> path_url()
    |> post(body, [])
    |> expect_accepted()
  end

  @doc "Posts a handler failure for `request_id`."
  def invocation_error(request_id, %{} = payload, error_type) do
    "/runtime/invocation/#{request_id}/error"
    |> path_url()
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
    |> path_url()
    |> post(encode!(payload), error_type_header(error_type))
    |> expect_accepted()
  end

  ## Private functions

  defp error_type_header(error_type) do
    [{~c"Lambda-Runtime-Function-Error-Type", String.to_charlist(error_type)}]
  end

  defp post(url, body, headers) do
    request = {url, headers, @json_content_type, IO.iodata_to_binary(body)}

    request(:post, request, timeout: @post_timeout)
  end

  defp request(method, request, http_opts) do
    http_opts =
      Keyword.merge([connect_timeout: @connect_timeout, autoredirect: false], http_opts)

    case :httpc.request(method, request, http_opts, [body_format: :binary], @profile) do
      {:ok, {{_http_vsn, status, _reason}, headers, body}} ->
        {:ok, status, normalize_headers(headers), body}

      {:error, reason} ->
        {:error, reason}
    end
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

  # httpc returns header names as lowercased charlists; make them binaries.
  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} ->
      {name |> List.to_string() |> String.downcase(), List.to_string(value)}
    end)
  end

  defp path_url(path) do
    endpoint = api_endpoint()

    String.to_charlist("http://" <> endpoint <> "/" <> @api_version <> path)
  end

  defp encode!(payload) do
    JSON.encode_to_iodata!(payload)
  end

  defp api_endpoint do
    if endpoint = :persistent_term.get(@persistent_term_key, nil) do
      endpoint
    else
      endpoint =
        System.get_env("AWS_LAMBDA_RUNTIME_API") ||
          raise """
          AWS_LAMBDA_RUNTIME_API is not set.

          This process is meant to be started by the Lambda sandbox through the
          `bootstrap` script. To run it locally, point it at the AWS Lambda
          Runtime Interface Emulator (see README).
          """

      :ok = :persistent_term.put(@persistent_term_key, endpoint)

      endpoint
    end
  end
end
