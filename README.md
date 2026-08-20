# AWS.Lambda.Runtime

A dependency-free [AWS Lambda custom runtime](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-custom.html)
for Elixir.

`AWS.Lambda.Runtime` implements the [Lambda Runtime API](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html)
directly on top of `:inets`/`:httpc` and the OTP-bundled `JSON` module — no
HTTP client, no JSON library, and no other dependency beyond what ships with
Erlang/OTP itself. It also wires up the `mix release` steps needed to package
a function for the `provided.al2023` runtime.

## Installation

Add `aws_lambda_runtime` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:aws_lambda_runtime, "~> 0.1.0"}
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
    {:aws_lambda_runtime, "~> 0.1.0"}
  ]
end
```

Fetch it:

```sh
mix deps.get
```

Then, inside `project/0`, declare the release, and add a private `releases/0`
function that wires up the steps `:aws_lambda_runtime` needs to turn a plain
release into a Lambda-ready package:

```elixir
def project do
  [
    app: :hello_function,
    version: "0.1.0",
    elixir: "~> 1.18",
    start_permanent: Mix.env() == :prod,
    deps: deps(),
    releases: releases()
  ]
end
```

```elixir
defp releases do
  [
    lambda: [
      include_erts: false,
      include_executables_for: [:unix],
      strip_beams: true,
      quiet: true,
      steps: [
        :assemble,
        &AWS.Lambda.Runtime.Release.copy_bootstrap/1,
        &AWS.Lambda.Runtime.Release.copy_release_files/1
      ]
    ]
  ]
end
```

`include_erts: false` because ERTS comes from the Lambda layer, see below.
`copy_bootstrap/1` and `copy_release_files/1` run after `:assemble` and copy
the `bootstrap` entrypoint and the `vm.args`/`env.sh` files Lambda's
`provided.al2023` runtime expects — running them as steps (rather than at
`project/0` evaluation time) guarantees `:aws_lambda_runtime` is already
compiled and loaded.

### 3. Write a handler

A handler is any module that implements the `AWS.Lambda.Runtime.Handler`
behaviour — a `handle_event/2`-shaped function receiving the decoded event
and an `AWS.Lambda.Runtime.Context` struct:

```elixir
defmodule HelloFunction do
  alias AWS.Lambda.Runtime.Context
  alias AWS.Lambda.Runtime.Handler

  @behaviour Handler

  @impl Handler
  def handler(event, context) do
    {:ok,
     %{
       message: "hello from Elixir on #{:erlang.system_info(:otp_release)}",
       received: event,
       request_id: context.request_id,
       remaining_ms: Context.remaining_time_ms(context)
     }}
  end
end
```

Point the function's *Handler* setting at it, e.g. `HelloFunction` or
`HelloFunction.handler` — see the `AWS.Lambda.Runtime.Handler` moduledoc for
every accepted format.

### 4. Build and deploy

```sh
mix aws_lambda.build 29.0.5 1.20.3 --output .
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
PLATFORM=arm64 OTP_VERSION=29.0.5; \
aws lambda create-function \
  --function-name elixir-hello \
  --runtime provided.al2023 \
  --architectures "$PLATFORM" \
  --role arn:aws:iam::000000000000:role/lambda-elixir \
  --handler bootstrap \
  --zip-file fileb://function.zip \
  --layers "arn:aws:lambda:eu-west-3:226873539218:layer:erlang-otp-${OTP_VERSION}"
```

Replace the role ARN, layer ARN/region and account ID with your own. On
subsequent deploys, update the function code instead of recreating it:

```sh
aws lambda update-function-code --publish --function-name elixir-hello \
  --zip-file fileb://function.zip \
  && aws lambda wait function-updated --function-name elixir-hello
```

## Performance

Rough numbers for the `HelloFunction` example above, deployed with 512MB of
memory:

- **Cold start:** ~1.5-2s
- **Execution time:** ~2ms
- **Memory used:** ~180MB
- **Cost:** ~$0.0000135334 per call in `us-east-1`

## The AWS Layer for OTP

Because releases are built with `include_erts: false`, the function package
only ships Elixir and your own code — the Erlang/OTP runtime itself must come
from a Lambda layer mounted at `/opt/otp`, matching the OTP version the
release was built against.

Prebuilt layer zips are published as GitHub release assets (see
[`docker/erlang`](docker/erlang/README.md) for how they're built). Available
releases:

- Erlang 29.0.5: https://github.com/GRoguelon/aws_lambda_runtime/releases/tag/erlang-29.0.5

Download the one matching your OTP version and architecture, and publish it
as a layer version:

```sh
OTP_VERSION=29.0.5 PLATFORM=amd64 AWS_PROFILE=default AWS_REGION=us-east-1; \
curl -fsSL -o layer.zip "https://github.com/GRoguelon/aws_lambda_runtime/releases/download/erlang-${OTP_VERSION}/lambda-layer-erlang-${OTP_VERSION}-${PLATFORM}.zip" \
  && aws lambda publish-layer-version \
       --layer-name "erlang-otp-${OTP_VERSION}" \
       --zip-file fileb://layer.zip \
       --compatible-architectures "$PLATFORM" \
       --compatible-runtimes provided.al2023 \
  && rm layer.zip
```

`PLATFORM` is `amd64` or `arm64` (matching Lambda's own architecture names)
and must correspond to the architecture your function is built/deployed for.
`OTP_VERSION` must match the version your release was compiled against.

## Trademarks

"AWS", "Amazon Web Services", and "AWS Lambda" are trademarks of Amazon.com,
Inc. or its affiliates. This project is an independent, community-maintained
library and is not affiliated with, endorsed by, or sponsored by Amazon.com,
Inc. or its affiliates.
