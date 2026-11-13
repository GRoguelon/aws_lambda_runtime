# Writing a handler

A handler is a module implementing the `AWS.Lambda.Runtime.Handler`
behaviour:

```elixir
defmodule HelloFunction do
  @behaviour AWS.Lambda.Runtime.Handler

  alias AWS.Lambda.Runtime.Context
  alias AWS.Lambda.Runtime.Request

  @impl true
  def init(_info) do
    {:ok, %{otp_release: :erlang.system_info(:otp_release)}}
  end

  @impl true
  def handle(%Request{method: "GET", path: "/hello", query: query}, _context, state) do
    {:ok, %{message: "hello #{query["name"]} from Elixir on #{state.otp_release}"}}
  end

  def handle(event, context, state) do
    {:ok,
     %{
       message: "hello from Elixir on #{state.otp_release}",
       received: event,
       request_id: context.request_id,
       remaining_ms: Context.remaining_time_ms(context)
     }}
  end
end
```

## Callbacks

- **`init/1`**, optional, runs once per execution environment during Lambda's
  init phase, once every application has started, the function's own
  included: it can query an `Ecto.Repo` the application started. The state
  it returns is passed to every `handle/3`, which can't change it.
- **`handle/3`** gets the event ready to use:
  - an `AWS.Lambda.Runtime.Request` for an HTTP request from a Function URL
    or API Gateway, with its query string, cookies and body already decoded
    (JSON and forms into maps), see [HTTP requests](http.md);
  - a struct for an event from SQS, SNS, S3, EventBridge, Kinesis or DynamoDB
    Streams, such as `%AWS.Lambda.Runtime.Events.SQS{records: messages}`,
    with S3 keys URL-decoded, Kinesis data decoded from base64 and DynamoDB
    images as plain maps, see [AWS service events](events.md);
  - the payload decoded from JSON for anything else, such as a direct
    invocation.
- **`terminate/2`**, optional, runs when Lambda shuts the execution
  environment down (see [Graceful shutdown](graceful-shutdown.md)).

## Return values

It returns `{:ok, body}`, `{:ok, body, opts}`, `{:stream, chunks}` or
`{:stream, chunks, opts}`, `{:retry, failed}` to have only the failed
records of an SQS, Kinesis or DynamoDB Streams batch retried, or
`{:error, reason}` for a function error. For an
HTTP request, `opts` can set the response's `:status`, `:headers` and
`:cookies`, and the runtime encodes it as the Function URL or API Gateway
expects it. `:content_type` returns a binary body as is rather than in JSON.

When no `handle/3` clause matches, the runtime answers an HTTP request with a
`404`, and reports any other event as a `Runtime.UnhandledEvent` function
error, with the event in the logs.

A module defining `handler/2` instead, which receives the event decoded from
JSON as is and no state, still works: see the `AWS.Lambda.Runtime.Handler`
moduledoc.

## Where the handler comes from

The runtime calls the first handler set of:

1. the release's `handler:` option, checked when the release is built, so a
   typo fails the build rather than the cold start:

   ```elixir
   releases: [lambda: fn -> AWS.Lambda.Runtime.Release.lambda(handler: HelloFunction) end]
   ```

2. the application config:

   ```elixir
   import Config

   config :aws_lambda_runtime, handler: HelloFunction
   ```

3. the function's *Handler* setting, set when creating the function (see
   [Getting started](getting-started.md#5-push-to-aws)). As it is read at each cold start, one package can serve several
   functions, each with its own handler.

Each takes a module, `HelloFunction` (calls `handle/3`), or a function,
`{HelloFunction, :some_function}` or `HelloFunction.some_function` as a
string: see the `AWS.Lambda.Runtime.Handler` moduledoc for every accepted
format. Lambda requires a *Handler* setting even when the handler comes from
the release or the config: any value then does.
