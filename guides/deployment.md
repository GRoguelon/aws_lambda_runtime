# Deployment: OTP layer or embedded ERTS

A release built with `include_erts: false`, the default, ships Elixir and
your own code, and runs on an OTP layer attached to the function. With
`include_erts: true`, it carries the Erlang runtime system itself, and needs
no layer.

## Embedding ERTS

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

## The OTP layer

Unless the release embeds ERTS, the function package only ships Elixir and
your own code — the Erlang/OTP runtime itself must come from a Lambda layer
mounted at `/opt/otp`, matching the OTP version the release was built
against.

Prebuilt layer zips are published as GitHub release assets (see
[`docker/erlang`](https://github.com/GRoguelon/aws_lambda_runtime/blob/main/docker/erlang/README.md) for how they're built). Available
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
