# Docker Images

Build assets for the runtimes used by this project's AWS Lambda functions:
an Erlang/OTP AWS Lambda layer, and an Elixir Docker image built on top of
it. Each subdirectory is self-contained with its own `Dockerfile` and
`Makefile`.

## [erlang/](erlang/README.md)

Compiles Erlang/OTP from source into a minimal runtime, published two ways:

- a Docker image (`ghcr.io/groguelon/lambda-layer-erlang`)
- an AWS Lambda layer zip (`/opt/otp` + `/opt/lib`), extracted from that
  image and written to `../out/`

This is the foundation both the Elixir image and any Erlang-based Lambda
function build on.

## [elixir/](elixir/README.md)

Installs Elixir on top of the Erlang layer image and publishes it as a
Docker image (`ghcr.io/groguelon/lambda-layer-elixir`). It does not produce
a Lambda layer zip — instead, the `aws_lambda_runtime` library's
`mix aws_lambda.build` task uses this image as a build container to
compile a Mix release and package it into an AWS Lambda function zip. See
its README for details.

## Typical order of operations

1. Build and publish the Erlang layer (`erlang/`), since the Elixir image
   depends on it as a base image.
2. Build and publish the Elixir image (`elixir/`).

Both directories expose the same shape of Makefile targets (`build`,
`push`, `merge-images`, `all`, `help`) with `PLATFORM`/version variables
overridable on the command line — see each README for details.

## Automated builds

The [`Docker images`](../.github/workflows/docker-images.yml) workflow runs
daily (and on demand from the Actions tab, with an optional dry run). It
looks up the latest Erlang/OTP patch of every major from `OTP_MIN_MAJOR` on,
and the latest Elixir patch of every minor from `ELIXIR_MIN_MINOR` on that
Hex has built for it, then builds whatever is missing from the registry:

1. the Erlang image for each architecture on a native runner, the merged
   multi-arch image, and an `erlang-<version>` GitHub release holding both
   layer zips;
2. then the Elixir images on top of it.

Images that already exist are only rebuilt when the manual run is started
with "rebuild" ticked. To backfill older versions,
lower `OTP_MIN_MAJOR`/`ELIXIR_MIN_MINOR` in the workflow.
