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
    {:aws_lambda_runtime, "~> 0.2.0"}
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
    {:aws_lambda_runtime, "~> 0.2.0"}
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
the Lambda layer (see below), plus the `bootstrap` entrypoint and the
`vm.args`/`env.sh` files copied into the package. The anonymous function defers
the call until `mix release` runs, once `:aws_lambda_runtime` is compiled and
loaded. The release must be named `lambda`, as `bootstrap` starts
`bin/lambda`.

Any `mix release` option given to `lambda/1` overrides its defaults, and it
accepts a few options of its own:

- `strip_iex: true` removes IEx from the release, for a smaller package.
- `before_steps:` and `after_steps:` add steps before and after the others.

```elixir
releases: [
  lambda: fn ->
    AWS.Lambda.Runtime.Release.lambda(strip_iex: true, after_steps: [:tar])
  end
]
```

### 3. Write a handler

A handler is any module that implements the `AWS.Lambda.Runtime.Handler`
behaviour — a `handler/2` function receiving the decoded event and an
`AWS.Lambda.Runtime.Context` struct:

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

Lambda passes the function's *Handler* setting to the runtime, which calls
the module it names: `HelloFunction` (calls `handler/2`) or
`HelloFunction.some_function` — see the `AWS.Lambda.Runtime.Handler`
moduledoc for every accepted format. It is set when creating the function in
step 5.

The handler can be set in `config/config.exs` instead, which takes precedence
over the *Handler* setting:

```elixir
import Config

config :aws_lambda_runtime, handler: HelloFunction
```

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
the layer's. On subsequent deploys, update the function code instead of
recreating it:

```sh
aws lambda update-function-code --publish --function-name elixir-hello \
  --zip-file fileb://function.zip \
  && aws lambda wait function-updated --function-name elixir-hello
```

## Streaming responses

A handler can stream its response instead of returning it all at once, by
returning `{:stream, chunks}` or `{:stream, chunks, opts}`, where `chunks` is
any enumerable of iodata, such as a `Stream`:

```elixir
def handler(%{"count" => count}, _context) do
  chunks = Stream.map(1..count, &"data: #{&1}\n\n")

  {:stream, chunks,
   content_type: "text/event-stream",
   http: [headers: %{"cache-control" => "no-cache"}]}
end
```

Each element is sent as soon as it is produced. `http:` sets the status,
headers and cookies a Function URL responds with; leave it out for
`InvokeWithResponseStream` callers. See the `AWS.Lambda.Runtime.Handler`
moduledoc for every option, and for how an error is reported once streaming
has started.

Lambda only streams to callers that ask for it: a Function URL in
`RESPONSE_STREAM` mode,

```sh
aws lambda create-function-url-config --function-name elixir-hello \
  --auth-type NONE --invoke-mode RESPONSE_STREAM
aws lambda add-permission --function-name elixir-hello \
  --statement-id FunctionURLAllowPublicAccess --action lambda:InvokeFunctionUrl \
  --principal "*" --function-url-auth-type NONE
aws lambda add-permission --function-name elixir-hello \
  --statement-id FunctionURLInvokeFunction --action lambda:InvokeFunction \
  --principal "*" --invoked-via-function-url
curl -N https://<url-id>.lambda-url.<region>.on.aws/
```

(`NONE` makes the URL public: anyone with it can invoke the function. A
public URL needs both permissions; `--invoked-via-function-url` limits the
second one to calls made through the URL. See the Lambda documentation on
Function URLs for `AWS_IAM` authentication.), or the `InvokeWithResponseStream`
API:

```sh
aws lambda invoke-with-response-stream --function-name elixir-hello \
  --cli-binary-format raw-in-base64-out --payload '{"count": 3}' /dev/stdout
```

Other callers, the Lambda console included, receive the whole response once
it is complete. API Gateway doesn't stream Lambda responses.

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

## The AWS Layer for OTP

Because releases are built with `include_erts: false`, the function package
only ships Elixir and your own code — the Erlang/OTP runtime itself must come
from a Lambda layer mounted at `/opt/otp`, matching the OTP version the
release was built against.

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
