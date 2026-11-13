# Tracing with X-Ray

With the function's tracing mode set to `Active`, Lambda records each
sampled invocation in [X-Ray](https://docs.aws.amazon.com/xray/latest/devguide/aws-xray.html),
in a segment for the function with the cold start's `Init` and the runtime's
`Overhead`, but nothing of what the handler does. The function's
role needs the `AWSXRayDaemonWriteAccess` managed policy, or the
`xray:PutTraceSegments` and `xray:PutTelemetryRecords` permissions:

```sh
aws lambda update-function-configuration --function-name elixir-hello \
  --tracing-config Mode=Active
```

`AWS.Lambda.Runtime.XRay` adds what the handler does to the trace, as
subsegments of the invocation's segment:

```elixir
alias AWS.Lambda.Runtime.XRay

def handle(%{"user_id" => id}, _context, _state) do
  user =
    XRay.subsegment("load_user", fn -> Repo.get(User, id) end,
      annotations: %{user_id: id}
    )

  {:ok, %{name: user.name}}
end
```

- A subsegment started inside another is recorded as its child. In another
  process, such as a `Task`, pass it the header of the one to attach to:
  `trace_header: XRay.trace_header()`.
- A raise, throw or exit marks the subsegment as a fault, with its stack
  trace, and is let through.
- A call to another service joins the trace when it carries
  `XRay.trace_header()` in its `X-Amzn-Trace-Id` header.
- `XRay.put_annotation/2`, `XRay.put_metadata/2` and
  `XRay.update_subsegment/1` add to the open subsegment what is only known
  once it has started, such as a response status.

Subsegments are sent over UDP to the X-Ray daemon Lambda runs in the sandbox,
without waiting for it. Nothing is sent when the invocation isn't sampled.

Traces show up in the CloudWatch console, under *X-Ray traces*, a few
seconds after the invocation: the *Traces* page lists them (filter on
`service("elixir-hello")`), and the *Trace Map* draws the function and the
services it calls.

## From telemetry events

When the function depends on [`:telemetry`](https://hex.pm/packages/telemetry),
as it does through Ecto, Finch or Req, `AWS.Lambda.Runtime.XRay.Telemetry`
records subsegments from the events these libraries emit, without wrapping
each call. Attach it once, from the function's application, which `mix new`
doesn't create: declare it in `mix.exs`,

```elixir
def application do
  [
    extra_applications: [:logger],
    mod: {HelloFunction.Application, []}
  ]
end
```

then attach the handlers when it starts:

```elixir
defmodule HelloFunction.Application do
  use Application

  @impl Application
  def start(_type, _args) do
    AWS.Lambda.Runtime.XRay.Telemetry.attach(
      ecto: [:hello_function, :repo],
      finch: true,
      spans: [[:hello_function, :checkout]]
    )

    Supervisor.start_link([HelloFunction.Repo], strategy: :one_for_one)
  end
end
```

- `ecto:` records each query of the repo with that telemetry prefix, with its
  SQL but not its parameters.
- `finch: true` records each HTTP request made with Finch or Req, with its
  method, URL (without its query string) and response status.
- `spans:` records each `:telemetry.span/3` call with one of these prefixes.

`:telemetry` stays optional: the module is only compiled when the function
depends on it.
