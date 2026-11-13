# Getting started

The steps below take you from a blank `mix new` project to a function
running on Lambda.

## 1. Create the function app

```sh
mix new hello_function
cd hello_function
```

## 2. Add the dependency and wire up releases

Add `aws_lambda_runtime` to `deps/0` in `mix.exs`:

```elixir
defp deps do
  [
    {:aws_lambda_runtime, "~> 0.5.0"}
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
the [OTP layer](deployment.md#the-otp-layer) by default, plus the `bootstrap`
entrypoint and the `vm.args`/`env.sh` files copied into the package. The anonymous function defers
the call until `mix release` runs, once `:aws_lambda_runtime` is compiled and
loaded. The release must be named `lambda`, as `bootstrap` starts
`bin/lambda`.

Any `mix release` option given to `lambda/1` overrides its defaults, and it
accepts a few options of its own:

- `handler:` sets the function's handler (see [Writing a handler](handlers.md#where-the-handler-comes-from)).
- `include_erts: true` embeds ERTS in the package, so the function needs no
  OTP layer (see [Deployment](deployment.md)).
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

## 3. Write a handler

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

`init/1` builds a state once per execution environment, and `handle/3`
receives each invocation's event ready to use: see [Writing a
handler](handlers.md) for what it receives, what it can return, and where the
runtime finds it.

## 4. Build and deploy

```sh
mix aws_lambda.build 29.1.2 1.20.5 --output .
```

builds the release inside the prebuilt [`lambda-layer-elixir`](https://github.com/GRoguelon/aws_lambda_runtime/blob/main/docker/elixir/README.md)
Docker image — for the given Erlang and Elixir versions — and downloads the
resulting `function.zip` to the current directory, ready to be uploaded as a
Lambda function package. Building inside the image guarantees the release
matches the target `provided.al2023` runtime regardless of your local
OS/architecture. See `mix help aws_lambda.build` for the full list of
options (`--release`, `--platform`, `--dep`, ...).

## 5. Push to AWS

Create the function once, referencing the [OTP layer](deployment.md#the-otp-layer) you published:

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
