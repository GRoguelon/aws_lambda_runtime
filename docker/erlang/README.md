# Erlang Lambda Layer

Builds a minimal Erlang/OTP runtime, packaged both as a Docker image and as
an AWS Lambda layer, so Lambda functions running on the
`public.ecr.aws/lambda/provided:al2023` base image can execute Erlang code.

## What it does

The `Dockerfile` compiles Erlang/OTP from source in two stages:

- **`build-erlang` stage** — installs the toolchain (gcc, make, OpenSSL,
  unixODBC, ncurses, etc.), downloads and builds OTP with SSL, ODBC and JIT
  support enabled, then strips the result down for Lambda:
  - removes docs, examples, and dev-only applications
    (`dialyzer`, `edoc`, `common_test`, `eunit`, `xmerl`, ...)
  - strips debug symbols from binaries and shared objects
  - copies the runtime shared libraries (`libssl`, `libcrypto`, `libodbc`,
    `libncurses`, ...) that the Lambda execution environment doesn't already
    provide into `/opt/lib`
- **`final` stage** — a clean copy of the Lambda base image with just
  `/opt/otp` (the OTP install) and `/opt/lib` (extra shared libs) copied in.
  This is what gets pushed as the Docker image and extracted into the
  Lambda layer zip.

The final image's `/opt` layout matches exactly what Lambda mounts a layer
at, so `/opt/otp` and `/opt/lib` can be copied straight out of the image
and zipped up as-is.

## Requirements

- Docker with `buildx` (for multi-platform builds and `imagetools`)
- Push access to the target container registry (defaults to
  `ghcr.io/groguelon/lambda-layer-erlang`)

## Makefile targets

Run `make` or `make help` to list targets and current config values.

| Target | Description |
| --- | --- |
| `make build` | Build the Docker image for the current (or given) `PLATFORM`. |
| `make push` | Push the built image to the container registry. |
| `make extract` | Create a container from the image, copy `/opt/otp` and `/opt/lib` out of it, and zip them into an AWS Lambda layer under `../../out/`. |
| `make merge-images` | Combine the `arm64` and `amd64` images into a single multi-arch manifest tagged `$(BASE_TAG)`. |
| `make all` | Full pipeline: build, push and extract for `arm64`, then for `amd64`, then merge the two images. |
| `make help` | Show available targets and the resolved configuration. |

### Configuration variables

All of these can be overridden on the command line, e.g.
`make build OTP_VERSION=27.2 PLATFORM=amd64`.

| Variable | Default | Description |
| --- | --- | --- |
| `OTP_VERSION` | `29.0.5` | Erlang/OTP version to build. |
| `LAMBDA_IMAGE` | `public.ecr.aws/lambda/provided:al2023` | Base image used for both build and final stages. |
| `PLATFORM` | detected from `uname -m` (`amd64` or `arm64`) | Target architecture; maps to Docker's `linux/amd64` / `linux/arm64`. |
| `BASE_TAG` | `ghcr.io/groguelon/lambda-layer-erlang:$(OTP_VERSION)` | Registry tag without the platform suffix. |
| `IMAGE_TAG` | `$(BASE_TAG)-$(PLATFORM)` | Per-platform image tag actually built/pushed. |
| `OUT_DIR` | `../../out` | Where the layer zip is written. |
| `ZIP_FILE` | `lambda-layer-erlang-$(OTP_VERSION)-$(PLATFORM).zip` | Name of the generated layer archive. |

## Typical workflow

Build a layer for your local architecture only:

```sh
make build
make extract
```

Build, push and package the layer for both architectures, then publish a
combined multi-arch image:

```sh
make all OTP_VERSION=29.0.5
```

The resulting Lambda layer zip(s) are written to `../../out/`, ready to be
published with `aws lambda publish-layer-version`.
