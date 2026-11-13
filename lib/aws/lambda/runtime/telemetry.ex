defmodule AWS.Lambda.Runtime.Telemetry do
  @moduledoc """
  The `:telemetry` events the runtime emits, when the function depends on
  `:telemetry`, as it does through Ecto, Finch or Req. Without it, none is.

  ## `[:aws_lambda_runtime, :init, :stop]`

  Once `c:AWS.Lambda.Runtime.Handler.init/1` has returned.

    * Measurements: `:duration`, in `:native` time units.
    * Metadata: `:handler`, the `{module, function, arity}` called.

  ## `[:aws_lambda_runtime, :invocation, :start]`

  Before the handler is called.

    * Measurements: `:system_time`, `:monotonic_time`.
    * Metadata:
        * `:request_id`, `:context` - the invocation's.
        * `:handler` - the `{module, function, arity}` called.
        * `:event_type` - `:request` for an `AWS.Lambda.Runtime.Request`,
          `:sqs`, `:sns`, `:s3`, `:event_bridge`, `:kinesis` or `:dynamodb`
          for an event of `AWS.Lambda.Runtime.Events`, `:event` otherwise.
        * `:cold_start` - `true` for the execution environment's first
          invocation.

  ## `[:aws_lambda_runtime, :invocation, :stop]`

  Once the handler has returned, its stream included.

    * Measurements: `:duration`, `:monotonic_time`.
    * Metadata: `:start`'s, plus `:result`: `:ok`, `:error` (it returned
      `{:error, reason}`), `:retry`, `:stream`, `:unmatched` (no clause
      matched) or `:timeout`.

  ## `[:aws_lambda_runtime, :invocation, :exception]`

  When the handler raised, threw or exited.

    * Measurements: `:duration`, `:monotonic_time`.
    * Metadata: `:start`'s, plus `:kind`, `:reason` and `:stacktrace`.

  The invocation events are emitted from the runtime's process, not the one
  the handler runs in. An invocation answered without calling the handler,
  such as a request whose body can't be decoded, emits none.
  """

  ## Public functions

  if Code.ensure_loaded?(:telemetry) do
    @doc false
    def execute(event, measurements, metadata) do
      :telemetry.execute(event, measurements, metadata)
    end
  else
    @doc false
    def execute(_event, _measurements, _metadata) do
      :ok
    end
  end
end
