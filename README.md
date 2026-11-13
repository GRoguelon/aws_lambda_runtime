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
    {:aws_lambda_runtime, "~> 0.5.0"}
  ]
end
```

## Quick start

Declare a release named `lambda` in `mix.exs`, with your handler. Embedding
ERTS (`include_erts: true`) spares you an OTP layer to publish:

```elixir
def project do
  [
    app: :hello_function,
    version: "0.1.0",
    elixir: "~> 1.18",
    deps: deps(),
    releases: [
      lambda: fn ->
        AWS.Lambda.Runtime.Release.lambda(handler: HelloFunction, include_erts: true)
      end
    ]
  ]
end
```

Write the handler:

```elixir
defmodule HelloFunction do
  @behaviour AWS.Lambda.Runtime.Handler

  @impl true
  def handle(event, _context, _state) do
    {:ok, %{message: "hello from Elixir", received: event}}
  end
end
```

Build the package in the Lambda builder image, for the given Erlang and
Elixir versions, then create the function and invoke it:

```sh
mix deps.get
mix aws_lambda.build 29.1.2 1.20.5 --output .

aws lambda create-function --function-name elixir-hello \
  --runtime provided.al2023 --architectures arm64 \
  --role arn:aws:iam::000000000000:role/lambda-elixir \
  --handler HelloFunction --zip-file fileb://function.zip

aws lambda invoke --function-name elixir-hello \
  --cli-binary-format raw-in-base64-out --payload '{"name":"Ada"}' out.json
```

Replace the role ARN with your own. [Getting started](guides/getting-started.md)
goes through each step.

## Guides

- [Getting started](guides/getting-started.md): from `mix new` to a
  function on Lambda, and the release's options.
- [Writing a handler](guides/handlers.md): `init/1`, `handle/3`,
  `terminate/2`, what they receive and return, and where the runtime finds
  the handler.
- [HTTP requests](guides/http.md): Function URLs and API Gateway, the decoded
  request, the response, and a Function URL's invoke mode.
- [AWS service events](guides/events.md): SQS, SNS, S3, EventBridge, Kinesis
  and DynamoDB Streams, and partial batch failures.
- [Streaming responses](guides/streaming.md): sending the response as it is
  produced.
- [Deployment](guides/deployment.md): an OTP layer or an embedded ERTS, and
  publishing the layer.
- [Logging](guides/logging.md): log levels and the JSON log format.
- [Tracing with X-Ray](guides/xray.md): subsegments, by hand or from
  telemetry events.
- [Metrics and telemetry](guides/metrics.md): CloudWatch metrics through EMF,
  and the runtime's telemetry events.
- [Graceful shutdown](guides/graceful-shutdown.md): running code when Lambda
  shuts the execution environment down.
- [Lambda Managed Instances](guides/managed-instances.md): several
  invocations at once.
- [Performance and tuning](guides/performance.md): cold start numbers and VM
  flags.

## Development

```sh
mix deps.get
mix test
```

`:telemetry` is an optional dependency: CI also checks the library compiles
without it, with `MIX_ENV=prod mix compile --warnings-as-errors --no-optional-deps`.

The Docker images the functions are built in, and the OTP layers, come from
[`docker/`](https://github.com/GRoguelon/aws_lambda_runtime/blob/main/docker/README.md). Changes are listed in the
[CHANGELOG](CHANGELOG.md).

## License

MIT, see [LICENSE](https://github.com/GRoguelon/aws_lambda_runtime/blob/main/LICENSE).

## Trademarks

"AWS", "Amazon Web Services", and "AWS Lambda" are trademarks of Amazon.com,
Inc. or its affiliates. This project is an independent, community-maintained
library and is not affiliated with, endorsed by, or sponsored by Amazon.com,
Inc. or its affiliates.
