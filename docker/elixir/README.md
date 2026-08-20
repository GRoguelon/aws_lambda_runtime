# Elixir Lambda Image

Builds an Elixir toolchain on top of the [Erlang Lambda layer](../erlang)
image, packaged as a Docker image that Lambda functions running Elixir code
can use as a base.

## What it does

The `Dockerfile` builds Elixir in two stages, using the Erlang layer image
(`ghcr.io/groguelon/lambda-layer-erlang:$OTP_VERSION`) as its base for both:

- **`build-elixir` stage** — installs build tooling (`make`, `unzip`,
  `wget`), then:
  - looks up the Hex.pm build matching the requested `ELIXIR_VERSION` and
    the major OTP version it needs to be compiled against
    (`v$ELIXIR_VERSION-otp-$ERLANG_MAJOR`), downloads it and verifies its
    SHA-256 checksum against Hex's build manifest
  - installs it into `/ELIXIR_LOCAL` via `make install DESTDIR=...`
  - bootstraps `mix local.hex` and `mix local.rebar` so the image is ready
    to fetch dependencies and compile Mix projects
- **`final` stage** — a clean copy of the Erlang layer image with just
  `/usr/local` (the Elixir install, Hex and Mix archives) copied in from the
  build stage, plus `MIX_HOME`/`HEX_HOME` pointed at their final location.

Unlike the Erlang layer, this one is not extracted into an AWS Lambda layer
zip — it's published purely as a Docker image.

The `aws_lambda_runtime` Elixir library's `mix aws_lambda.build` task
(`lib/mix/tasks/aws_lambda.build.ex`) uses this image as its build
environment to generate an AWS Lambda function: it pulls
`ghcr.io/groguelon/lambda-layer-elixir:<elixir_version>-erlang-<otp_version>-<arch>`,
starts a container from it, copies the Mix project's source in, runs
`mix deps.get + release` inside the container, and zips up the resulting
release to produce the Lambda function package.

## Requirements

- Docker with `buildx` (for multi-platform builds and `imagetools`)
- Push access to the target container registry (defaults to
  `ghcr.io/groguelon/lambda-layer-elixir`)
- The matching Erlang layer image (`ERLANG_IMAGE`) must already exist in
  the registry, since it's used as the base for both build stages

## Makefile targets

Run `make` or `make help` to list targets and current config values.

| Target | Description |
| --- | --- |
| `make build` | Build the Docker image for the current (or given) `PLATFORM`. |
| `make push` | Push the built image to the container registry. |
| `make merge-images` | Combine the `arm64` and `amd64` images into a single multi-arch manifest tagged `$(BASE_TAG)`. |
| `make all` | Full pipeline: build and push for `arm64`, then for `amd64`, then merge the two images. |
| `make help` | Show available targets and the resolved configuration. |

### Configuration variables

All of these can be overridden on the command line, e.g.
`make build ELIXIR_VERSION=1.20.3 OTP_VERSION=29.0.5 PLATFORM=amd64`.

| Variable | Default | Description |
| --- | --- | --- |
| `OTP_VERSION` | `29.0.5` | Erlang/OTP version the Elixir build targets; also selects the Erlang base image tag. |
| `ELIXIR_VERSION` | `1.20.3` | Elixir version to install. |
| `ERLANG_IMAGE` | `ghcr.io/groguelon/lambda-layer-erlang:$(OTP_VERSION)` | Base image (build and final stage) — the [Erlang layer](../erlang) image. |
| `PLATFORM` | detected from `uname -m` (`amd64` or `arm64`) | Target architecture; maps to Docker's `linux/amd64` / `linux/arm64`. |
| `BASE_TAG` | `ghcr.io/groguelon/lambda-layer-elixir:$(ELIXIR_VERSION)-erlang-$(OTP_VERSION)` | Registry tag without the platform suffix. |
| `IMAGE_TAG` | `$(BASE_TAG)-$(PLATFORM)` | Per-platform image tag actually built/pushed. |

## Typical workflow

Build the image for your local architecture only:

```sh
make build
```

Build, push and publish a combined multi-arch image for a given
Elixir/OTP pair:

```sh
make all ELIXIR_VERSION=1.20.3 OTP_VERSION=29.0.5
```

Make sure the corresponding Erlang layer image has already been built and
pushed (see `../erlang`) before running this, since it's used as the base
image here.
