defmodule AWS.Lambda.Runtime.Context do
  @moduledoc """
  Per-invocation context, assembled from the `Lambda-Runtime-*` response headers
  of `GET /runtime/invocation/next` plus the static function environment.

  This is the second argument passed to your handler.
  """

  ## Module attributes

  defstruct [
    :request_id,
    :deadline_ms,
    :invoked_function_arn,
    :trace_id,
    :client_context,
    :identity,
    :function_name,
    :function_version,
    :memory_limit_mb,
    :log_group,
    :log_stream
  ]

  ## Public functions

  @doc """
  Builds a context from the response headers of `GET /runtime/invocation/next`,
  filling in the rest from the function's static environment variables.
  """
  def from_headers(headers) when is_map(headers) do
    %__MODULE__{
      request_id: headers["lambda-runtime-aws-request-id"],
      deadline_ms: to_integer(headers["lambda-runtime-deadline-ms"]),
      invoked_function_arn: headers["lambda-runtime-invoked-function-arn"],
      trace_id: headers["lambda-runtime-trace-id"],
      client_context: decode_json(headers["lambda-runtime-client-context"]),
      identity: decode_json(headers["lambda-runtime-cognito-identity"]),
      function_name: System.get_env("AWS_LAMBDA_FUNCTION_NAME"),
      function_version: System.get_env("AWS_LAMBDA_FUNCTION_VERSION"),
      memory_limit_mb: to_integer(System.get_env("AWS_LAMBDA_FUNCTION_MEMORY_SIZE")),
      log_group: System.get_env("AWS_LAMBDA_LOG_GROUP_NAME"),
      log_stream: System.get_env("AWS_LAMBDA_LOG_STREAM_NAME")
    }
  end

  @doc """
  Milliseconds left before Lambda kills the sandbox.

  The deadline is an absolute Unix timestamp in milliseconds, so this is
  computed against wall clock time rather than a monotonic clock.
  """
  def remaining_time_ms(%__MODULE__{deadline_ms: nil}) do
    :infinity
  end

  def remaining_time_ms(%__MODULE__{deadline_ms: deadline}) do
    max(deadline - System.system_time(:millisecond), 0)
  end

  ## Private functions

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} ->
        int

      :error ->
        nil
    end
  end

  defp to_integer(nil), do: nil

  defp decode_json(value) when value not in [nil, ""] do
    case JSON.decode(value) do
      {:ok, decoded} ->
        decoded

      {:error, _reason} ->
        nil
    end
  end

  defp decode_json(_value), do: nil
end
