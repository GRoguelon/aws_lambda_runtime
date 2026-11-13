# AWS.Lambda.Runtime

A dependency-free [AWS Lambda custom runtime](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-custom.html)
for Elixir.

`AWS.Lambda.Runtime` implements the [Lambda Runtime API](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html)
directly on top of `:gen_tcp` and the OTP-bundled `JSON` module — no HTTP
client, no JSON library, and no other dependency beyond what ships with
Erlang/OTP itself. It also wires up the `mix release` steps needed to package
a function for the `provided.al2023` runtime.

## Installation

Add `aws_lambda_runtime` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:aws_lambda_runtime, "~> 0.4.1"}
  ]
end
```

## Usage

The steps below take you from a blank `mix new` project to a function ready
to be packaged for Lambda.

### 1. Create the function app

```sh
mix new hello_function
cd hello_function
```

### 2. Add the dependency and wire up releases

Add `aws_lambda_runtime` to `deps/0` in `mix.exs`:

```elixir
defp deps do
  [
    {:aws_lambda_runtime, "~> 0.4.1"}
  ]
end
```

Fetch it:

```sh
mix deps.get
```

Then, inside `project/0`, declare a release named `lambda`:

```elixir
def project do
  [
    app: :hello_function,
    version: "0.1.0",
    elixir: "~> 1.18",
    start_permanent: Mix.env() == :prod,
    deps: deps(),
    releases: [lambda: fn -> AWS.Lambda.Runtime.Release.lambda() end]
  ]
end
```

`AWS.Lambda.Runtime.Release.lambda/1` returns the release options Lambda's
`provided.al2023` runtime needs: `include_erts: false` because ERTS comes from
the [OTP layer](#the-aws-layer-for-otp) by default, plus the `bootstrap`
entrypoint and the `vm.args`/`env.sh` files copied into the package. The anonymous function defers
the call until `mix release` runs, once `:aws_lambda_runtime` is compiled and
loaded. The release must be named `lambda`, as `bootstrap` starts
`bin/lambda`.

Any `mix release` option given to `lambda/1` overrides its defaults, and it
accepts a few options of its own:

- `handler:` sets the function's handler (see step 3).
- `include_erts: true` embeds ERTS in the package, so the function needs no
  OTP layer (see [Embedding ERTS](#embedding-erts-instead-of-the-otp-layer)).
- `strip_iex: true` removes IEx from the release, for a smaller package.
- `before_steps:` and `after_steps:` add steps before and after the others.

```elixir
releases: [
  lambda: fn ->
    AWS.Lambda.Runtime.Release.lambda(
      handler: HelloFunction,
      strip_iex: true,
      after_steps: [:tar]
    )
  end
]
```

### 3. Write a handler

A handler is a module implementing the `AWS.Lambda.Runtime.Handler`
behaviour. `handle/3` receives each invocation's event, an
`AWS.Lambda.Runtime.Context` struct, and the state `init/1` built:

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

- **`init/1`**, optional, runs once per execution environment during Lambda's
  init phase, once every application has started, the function's own
  included: it can query an `Ecto.Repo` the application started. The state
  it returns is passed to every `handle/3`, which can't change it.
- **`handle/3`** gets the event ready to use:
  - an `AWS.Lambda.Runtime.Request` for an HTTP request from a Function URL
    or API Gateway, with its query string, cookies and body already decoded
    (JSON and forms into maps);
  - a struct for an event from SQS, SNS, S3, EventBridge, Kinesis or DynamoDB
    Streams, such as `%AWS.Lambda.Runtime.Events.SQS{records: messages}`,
    with S3 keys URL-decoded, Kinesis data decoded from base64 and DynamoDB
    images as plain maps;
  - the payload decoded from JSON for anything else, such as a direct
    invocation.
- **`terminate/2`**, optional, runs when Lambda shuts the execution
  environment down (see [Graceful shutdown](#graceful-shutdown)).

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

3. the function's *Handler* setting, set when creating the function in
   step 5. As it is read at each cold start, one package can serve several
   functions, each with its own handler.

Each takes a module, `HelloFunction` (calls `handle/3`), or a function,
`{HelloFunction, :some_function}` or `HelloFunction.some_function` as a
string: see the `AWS.Lambda.Runtime.Handler` moduledoc for every accepted
format. Lambda requires a *Handler* setting even when the handler comes from
the release or the config: any value then does.

### 4. Build and deploy

```sh
mix aws_lambda.build 29.1.2 1.20.5 --output .
```

builds the release inside the prebuilt [`lambda-layer-elixir`](docker/elixir/README.md)
Docker image — for the given Erlang and Elixir versions — and downloads the
resulting `function.zip` to the current directory, ready to be uploaded as a
Lambda function package. Building inside the image guarantees the release
matches the target `provided.al2023` runtime regardless of your local
OS/architecture. See `mix help aws_lambda.build` for the full list of
options (`--release`, `--platform`, `--dep`, ...).

### 5. Push to AWS

Create the function once, referencing the OTP layer [published above](#the-aws-layer-for-otp):

```sh
aws lambda create-function \
  --function-name elixir-hello \
  --runtime provided.al2023 \
  --architectures arm64 \
  --role arn:aws:iam::000000000000:role/lambda-elixir \
  --handler HelloFunction \
  --zip-file fileb://function.zip \
  --layers arn:aws:lambda:us-east-1:000000000000:layer:erlang-otp-29-1-2-arm64:1
```

Replace the role ARN with your own, and the layer ARN with the one printed
when publishing the layer. `--architectures` (`arm64` or `x86_64`) must match
the layer's. A release built with `include_erts: true` needs no layer: drop
`--layers`, and match `--architectures` to `mix aws_lambda.build`'s
`--platform` (`linux/arm64` by default). On subsequent deploys, update the
function code instead of recreating it:

```sh
aws lambda update-function-code --publish --function-name elixir-hello \
  --zip-file fileb://function.zip \
  && aws lambda wait function-updated --function-name elixir-hello
```

## Streaming responses

A handler can stream its response instead of returning it all at once, by
returning `{:stream, chunks}` or `{:stream, chunks, opts}`, where `chunks` is
any enumerable of iodata, such as a `Stream`. Each element is sent as soon as
it is produced.

Lambda only streams to callers that ask for it: a Function URL in
`RESPONSE_STREAM` mode, or the `InvokeWithResponseStream` API. Other callers,
the Lambda console included, receive the whole response once it is complete,
and API Gateway doesn't stream Lambda responses.

See the `AWS.Lambda.Runtime.Handler` moduledoc for every option, and for how
an error is reported once streaming has started.

The two examples below extend the `HelloFunction` handler of step 3. Add
their `handle/3` clauses above the last one of step 3, which matches any
event and so must come last. Both stream a line every half second, from this
helper:

```elixir
defp chunks(count) do
  Stream.map(1..count, fn i ->
    Process.sleep(500)
    "chunk #{i} of #{count}\n"
  end)
end
```

The whole stream must be sent before the function's timeout, 3 seconds by
default: raise it for longer streams.

```sh
aws lambda update-function-configuration --function-name elixir-hello --timeout 15
```

### Example: streaming in reply to an event

Invoked through the `InvokeWithResponseStream` API, the handler receives the
payload as its event, like any invocation, and its chunks are sent as they
are:

```elixir
def handle(%{"stream" => count}, _context, _state) when is_integer(count) do
  {:stream, chunks(count), content_type: "text/plain"}
end
```

The AWS CLI doesn't offer `InvokeWithResponseStream`; call it from an AWS
SDK instead, e.g. with Python and boto3, printing each chunk as it arrives:

```python
import json

import boto3

response = boto3.client("lambda").invoke_with_response_stream(
    FunctionName="elixir-hello", Payload=json.dumps({"stream": 4})
)

for event in response["EventStream"]:
    if "PayloadChunk" in event:
        print(event["PayloadChunk"]["Payload"].decode(), end="", flush=True)
    elif error := event.get("InvokeComplete", {}).get("ErrorCode"):
        print(f"\nerror: {error}: {event['InvokeComplete'].get('ErrorDetails')}")
```

An error raised once streaming has started arrives in the final
`InvokeComplete` event, after the chunks sent before it.

### Example: streaming through a Function URL

A Function URL hands the handler an `AWS.Lambda.Runtime.Request`, and the
runtime sends the status, headers and cookies of the HTTP response before its
body (status `200` unless given):

```elixir
def handle(%Request{query: %{"stream" => count}}, _context, _state) do
  {:stream, chunks(String.to_integer(count)),
   content_type: "text/plain", headers: %{"cache-control" => "no-cache"}}
end
```

Create a URL in `RESPONSE_STREAM` mode, tell the runtime so (see below),
allow it to be called, and call it with `curl -N`, which prints each chunk as
it arrives:

```sh
aws lambda create-function-url-config --function-name elixir-hello \
  --auth-type NONE --invoke-mode RESPONSE_STREAM --query FunctionUrl --output text
aws lambda update-function-configuration --function-name elixir-hello \
  --environment '{"Variables": {"FUNCTION_URL_INVOKE_MODE": "RESPONSE_STREAM"}}'
aws lambda add-permission --function-name elixir-hello \
  --statement-id FunctionURLAllowPublicAccess --action lambda:InvokeFunctionUrl \
  --principal "*" --function-url-auth-type NONE
aws lambda add-permission --function-name elixir-hello \
  --statement-id FunctionURLInvokeFunction --action lambda:InvokeFunction \
  --principal "*" --invoked-via-function-url

curl -iN "https://<url-id>.lambda-url.<region>.on.aws/?stream=4"
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Transfer-Encoding: chunked
cache-control: no-cache
...

chunk 1 of 4
chunk 2 of 4
chunk 3 of 4
chunk 4 of 4
```

### The Function URL's invoke mode

Lambda reads a Function URL's response differently in each of its invoke
modes, without telling the function which one the URL uses: in
`RESPONSE_STREAM` mode it only reads a stream, in `BUFFERED` mode, the
default, only a response sent at once. The runtime sends either, whatever the
handler returns, once it knows the URL's mode, which it takes from, by
priority:

1. the function's `FUNCTION_URL_INVOKE_MODE` environment variable,
   `RESPONSE_STREAM` or `BUFFERED`, so the mode can follow the URL's without
   a new deployment (`--environment` replaces all the function's variables,
   so include the existing ones);
2. `config :aws_lambda_runtime, function_url: :response_stream` (or
   `:buffered`);
3. `BUFFERED`, the URL's default.

In `BUFFERED` mode, and for API Gateway, a `{:stream, …}` response is sent
once complete; with the wrong mode, the caller gets an empty body or the
response's envelope instead of its body.

To change a URL's mode, change the variable along with it. Lambda takes a few
minutes to apply the new mode everywhere: until then, some responses come
back with an empty body, whatever the function sends.

`NONE` makes the URL public: anyone with it can invoke the function. It
needs both permissions, and `--invoked-via-function-url` limits the second
one to calls made through the URL; without them, the URL answers `403
Forbidden`. See the Lambda documentation on Function URLs for `AWS_IAM`
authentication instead. Remove the URL and its permissions once done:

```sh
aws lambda delete-function-url-config --function-name elixir-hello
aws lambda remove-permission --function-name elixir-hello \
  --statement-id FunctionURLAllowPublicAccess
aws lambda remove-permission --function-name elixir-hello \
  --statement-id FunctionURLInvokeFunction
```

## Performance

Rough numbers for the `HelloFunction` example above, deployed on arm64 with
512MB of memory (Erlang 29.1.2, Elixir 1.20.5), medians of 20 cold starts:

- **Cold start:** ~495ms — ~455ms of init, then ~40ms for the first
  invocation, which loads the modules it uses, the release booting in
  interactive mode (see [Tuning the VM](#tuning-the-vm)).
- **Warm invocations:** ~2ms.
- **Memory used:** ~75MB.

## Tuning the VM

The release ships a `vm.args` tuned for Lambda: no scheduler busy waiting, no
distribution, and one scheduler per vCPU Lambda allocates, derived from the
function's memory size at start.

It also boots in interactive mode, loading each module the first time it is
called instead of all of them at boot, which shortens the init phase. Set the
function's `RELEASE_MODE` environment variable to `embedded` to preload every
module instead, so the first invocation doesn't pay for loading them.

Any other [`erl` flag](https://www.erlang.org/doc/apps/erts/erl_cmd.html) can
be added through the function's `ELIXIR_ERL_OPTIONS` environment variable,
without rebuilding the package. For instance, a handler building large terms
may garbage collect less with a bigger initial process heap (`+hms`, in words;
the default is 233):

```sh
aws lambda update-function-configuration --function-name elixir-hello \
  --environment '{"Variables": {"ELIXIR_ERL_OPTIONS": "+hms 1024"}}'
```

`--environment` replaces all the function's variables, so include the existing
ones. An `+S` given this way overrides the scheduler count derived from the
memory size.

## Logging

The runtime follows the function's logging configuration, which Lambda
passes to it as `AWS_LAMBDA_LOG_FORMAT` and `AWS_LAMBDA_LOG_LEVEL`:

```sh
aws lambda update-function-configuration --function-name elixir-hello \
  --logging-config LogFormat=JSON,ApplicationLogLevel=INFO
```

- **Level:** in both log formats, `Logger`'s level is, by priority:
  1. `AWS_LAMBDA_LOG_LEVEL` (`TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR` or
     `FATAL`; `TRACE` is `Logger`'s `:debug`), so verbosity can be changed in
     the function's configuration without a new deployment. A warning is
     logged at start when it overrides a different
     `config :logger, level: ...`;
  2. `config :logger, level: ...`;
  3. `:info` in the release, rather than `Logger`'s default `:debug`, which
     `iex -S mix` and tests keep.
- **JSON format:** each log entry is written as one line of JSON, with its
  `timestamp`, `level`, `message`, the `requestId` of the invocation, and the
  entry's `Logger` metadata. A multi-line message, such as a stack trace,
  stays a single CloudWatch Logs event.

```json
{"level":"INFO","message":"two\nlines","mfa":"MyApp.Handler.handle/3","requestId":"8f5…","timestamp":"2026-11-13T15:49:52.683Z","user_id":42}
```

In the `Text` format, entries are written by `Logger`'s default formatter.

## Tracing with X-Ray

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

### From telemetry events

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

## Graceful shutdown

Lambda shuts an execution environment down after it has been idle for a
while, or when the function is updated. To flush a buffer or close a
connection then, implement the handler's `terminate/2`, called with
`:shutdown` and `init/1`'s state:

```elixir
@impl true
def terminate(_reason, _state) do
  HelloFunction.Metrics.flush()
end
```

Code outside the handler, a library for instance, can register a function
of its own with `AWS.Lambda.Runtime.Shutdown.register/1`, before the first
invocation.

Lambda only sends a SIGTERM before shutting an environment down when an
extension is registered in it: with `terminate/2` or a function registered,
the runtime registers itself as an internal extension during the init phase,
so no extension layer is needed.

On SIGTERM, `terminate/2` and the registered functions run in order while
every application is still running, `Logger` is flushed, then the VM stops its applications,
which also runs their `stop/1` callbacks and the `terminate/2` of the
processes trapping exits. Lambda allows about 500 milliseconds for all of
it before killing the environment, so keep these functions short.

## Lambda Managed Instances

On Lambda Managed Instances, an execution environment handles several
invocations at once, as many as Lambda sets in `AWS_LAMBDA_MAX_CONCURRENCY`.
The runtime then polls for that many invocations, each handled in its own
process, as on standard Lambda, with nothing to change in the handler:

- `init/1` still runs once, and its state is shared by every invocation,
  which can only read it.
- Each invocation's logs carry its request ID, and X-Ray subsegments attach
  to its own trace: the trace header lives in the handler's process rather
  than in `_X_AMZN_TRACE_ID`, which isn't set then. A process the handler
  starts, such as a `Task`, attaches to it with
  `trace_header: XRay.trace_header()`.
- Only the environment's first invocation is a cold start, for the
  telemetry events.
- The VM keeps its own scheduler count, from the instance's vCPUs, rather
  than deriving it from the memory size as on standard Lambda.
- Lambda doesn't stop a handler at its deadline there: the runtime does, as
  everywhere.

## Embedding ERTS instead of the OTP layer

With `include_erts: true`, the package carries the Erlang runtime system
itself, and the function needs no layer:

```elixir
releases: [
  lambda: fn ->
    AWS.Lambda.Runtime.Release.lambda(handler: HelloFunction, include_erts: true)
  end
]
```

The release then also carries the shared libraries the OTP layer ships
alongside ERTS and the Lambda sandbox lacks (`libcrypto`,
`libtinfo`, `libstdc++`…), in its `lib/` directory, which Lambda puts on
`LD_LIBRARY_PATH`. Both come from the builder image, so the release must be
built with `mix aws_lambda.build`: built elsewhere, say with `mix release` on
macOS, it would embed an ERTS that can't run on Lambda, and the build stops
with an error.

Which one to pick:

- **Embedded ERTS:** one artifact, and no layer to publish in each region and
  account, nor to keep in step with the OTP version the release is built
  with. The package is larger, and uploaded on every deploy: for a function
  using Req, 12MB instead of 2MB (30MB unzipped), with the same init phase,
  about 500ms on arm64 with 512MB of memory.
- **OTP layer:** smaller packages and faster deploys, the layer being shared
  by every function using the same OTP version.

## The AWS Layer for OTP

Unless the release embeds ERTS, the function package only ships Elixir and
your own code — the Erlang/OTP runtime itself must come from a Lambda layer
mounted at `/opt/otp`, matching the OTP version the release was built
against.

Prebuilt layer zips are published as GitHub release assets (see
[`docker/erlang`](docker/erlang/README.md) for how they're built). Available
releases:

- Erlang 29.1.2: https://github.com/GRoguelon/aws_lambda_runtime/releases/tag/erlang-29.1.2
- Erlang 29.0.5: https://github.com/GRoguelon/aws_lambda_runtime/releases/tag/erlang-29.0.5

Download the one matching your OTP version and architecture, and publish it
as a layer version:

```sh
OTP_VERSION=29.1.2 PLATFORM=arm64 AWS_PROFILE=default AWS_REGION=us-east-1; \
ARCH=$([ "$PLATFORM" = amd64 ] && echo x86_64 || echo arm64); \
curl -fsSL -o layer.zip "https://github.com/GRoguelon/aws_lambda_runtime/releases/download/erlang-${OTP_VERSION}/lambda-layer-erlang-${OTP_VERSION}-${PLATFORM}.zip" \
  && aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lambda publish-layer-version \
       --layer-name "erlang-otp-$(echo "$OTP_VERSION" | tr . -)-${PLATFORM}" \
       --zip-file fileb://layer.zip \
       --compatible-architectures "$ARCH" \
       --compatible-runtimes provided.al2023 \
       --query LayerVersionArn --output text \
  && rm layer.zip
```

- `PLATFORM` is `arm64` or `amd64`, the asset to download. It must match the
  architecture your function is built and deployed for, which Lambda names
  `arm64` or `x86_64` (`ARCH`).
- `OTP_VERSION` must match the version your release was compiled against.
  Layer names can't contain dots, so the layer is named after it with dashes,
  e.g. `erlang-otp-29-1-2-arm64`.

The command prints the ARN of the layer version, e.g.
`arn:aws:lambda:us-east-1:000000000000:layer:erlang-otp-29-1-2-arm64:1`, to
attach to the function.

## Trademarks

"AWS", "Amazon Web Services", and "AWS Lambda" are trademarks of Amazon.com,
Inc. or its affiliates. This project is an independent, community-maintained
library and is not affiliated with, endorsed by, or sponsored by Amazon.com,
Inc. or its affiliates.
