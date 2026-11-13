# Metrics and telemetry

## Metrics

`AWS.Lambda.Runtime.Metrics` publishes CloudWatch metrics through the
Embedded Metric Format: each call writes a line of JSON to the function's
output, from which CloudWatch Logs publishes the metrics. There is no
CloudWatch API call, so no network round trip during the invocation and no
permission beyond the function's logs.

```elixir
alias AWS.Lambda.Runtime.Metrics

Metrics.count("HelloFunction", "OrdersPlaced")

Metrics.emit("HelloFunction", %{"OrderTotal" => 42.5, "Items" => {3, :count}},
  dimensions: %{"Channel" => "web"},
  properties: %{"orderId" => order.id}
)

order = Metrics.timing("HelloFunction", "ChargeLatency", fn -> charge(order) end)
```

Each combination of dimension values is a metric of its own, billed as such:
keep values such as user IDs in `properties:`, which CloudWatch Logs Insights
can search without publishing them. The line also carries the invocation's
request ID.

## Telemetry events

When the function depends on `:telemetry`, the runtime emits
`[:aws_lambda_runtime, :invocation, :start | :stop | :exception]` around each
call to the handler, with the request ID, the event's type (`:request`,
`:sqs`, `:s3`…), whether it's a cold start and, once done, its result
(`:ok`, `:error`, `:retry`, `:stream`, `:unmatched` or `:timeout`), and
`[:aws_lambda_runtime, :init, :stop]` once `init/1` has run. See
`AWS.Lambda.Runtime.Telemetry` for their measurements and metadata. For
instance, to publish each invocation's duration by event type as a metric:

```elixir
def init(_info) do
  :telemetry.attach(
    "invocation-metrics",
    [:aws_lambda_runtime, :invocation, :stop],
    &HelloFunction.Telemetry.handle_event/4,
    nil
  )

  {:ok, nil}
end
```

```elixir
defmodule HelloFunction.Telemetry do
  def handle_event(_event, %{duration: duration}, metadata, _config) do
    AWS.Lambda.Runtime.Metrics.emit(
      "HelloFunction",
      %{"HandlerDuration" => {System.convert_time_unit(duration, :native, :millisecond), :milliseconds}},
      dimensions: %{"EventType" => metadata.event_type, "Result" => metadata.result}
    )
  end
end
```
