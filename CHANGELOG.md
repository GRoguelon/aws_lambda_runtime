# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- The runtime waits until the release has started every application before
  polling the Runtime API. It used to start with `:aws_lambda_runtime`, before
  the function's own application, so the first invocation could reach a
  handler whose dependencies were not started yet, and their start-up was
  counted in the invocation instead of Lambda's init phase.
- The VM exits, as the Runtime API contract requires, when
  `GET /runtime/invocation/next` is answered with an error status, when it
  fails five times in a row, or when posting a result is answered with a
  `500` container error. It used to retry `/next` every 200 ms until the
  function timed out.

### Changed

- The scheduler count follows the function's memory size, one per vCPU
  Lambda allocates (`ceil(AWS_LAMBDA_FUNCTION_MEMORY_SIZE / 1769)`), instead
  of a fixed `+S 2:2`. It is set by `env.sh`; an `+S` in
  `ELIXIR_ERL_OPTIONS` takes precedence.
- `bootstrap` appends `-noinput` to `ELIXIR_ERL_OPTIONS` instead of
  overwriting it, so VM flags set in the function's environment are kept.
- `vm.args` no longer sets `+hms 1024`, which made every process start with a
  heap over four times the VM default (233 words). Set it through
  `ELIXIR_ERL_OPTIONS` if a handler benefits from it.
- Releases boot in interactive mode (`RELEASE_MODE=interactive`, set by
  `env.sh`), loading modules on first use instead of all at boot. Set
  `RELEASE_MODE=embedded` on the function to restore preloading.
- `:ssl` is no longer started: the Runtime API is plain HTTP, and starting
  `:ssl` (with `:crypto` and `:public_key`) only slowed the cold start.
  Handlers calling `:httpc` over HTTPS must add `:ssl` to their own
  `extra_applications`; HTTP clients such as Req, Finch or Hackney already
  depend on it.
- The Runtime API client is built on `:gen_tcp` (`AWS.Lambda.Runtime.HTTP`)
  instead of `:httpc`, so `:inets` is no longer started either. Handlers
  using `:httpc` must add `:inets` to their own `extra_applications`.

## [0.2.0] - 2026-11-10

### Added

- `AWS.Lambda.Runtime.Release.lambda/1` — returns the whole release
  configuration (`include_erts: false`, stripped beams, the `bootstrap`
  entrypoint and the `vm.args`/`env.sh` templates). Any `mix release` option
  overrides its defaults, and it accepts `:strip_iex`, `:before_steps` and
  `:after_steps`. Declare it lazily:
  `releases: [lambda: fn -> AWS.Lambda.Runtime.Release.lambda() end]`.
- `AWS.Lambda.Runtime.Release.strip_iex/1` — release step removing IEx from
  the package.
- `bootstrap` exits with a clear error when `bin/lambda` is missing, i.e.
  when the release isn't named `lambda`.
- The `lambda-layer-elixir` image ships `git`, `tar` and `zip`.

### Changed

- `mix aws_lambda.build` pulls the multi-arch
  `lambda-layer-elixir:<elixir>-erlang-<erlang>` image and selects the
  architecture with `--platform`, instead of always pulling the `-arm64` tag.
- `bootstrap` and the `vm.args`/`env.sh` templates are applied through
  `rel_templates_path` and its `overlays` directory, instead of being copied by
  custom steps.

### Removed

- `AWS.Lambda.Runtime.Release.copy_bootstrap/1` and
  `AWS.Lambda.Runtime.Release.copy_release_files/1` — replace the release
  configuration in `mix.exs` with `AWS.Lambda.Runtime.Release.lambda/1`.

[0.2.0]: https://github.com/GRoguelon/aws_lambda_runtime/releases/tag/v0.2.0

## [0.1.1] - 2026-08-20

### Added

- Docker build scripts (`docker/erlang`, `docker/elixir`) and READMEs for
  building the `lambda-layer-erlang` and `lambda-layer-elixir` images that
  `mix aws_lambda.build` pulls from.
- `mix aws_lambda.build` — `--dep`/`-d` flag to install extra `dnf` packages
  (e.g. `git`) in the build container alongside `tar`.

### Changed

- `mix aws_lambda.build` — colorized, more consistent step output; internal
  cleanup.

### Removed

- `AWS.Lambda.Runtime.MixRelease` (`priv/mix/release.exs`) — the release
  steps it configured are documented directly in the README instead.

[0.1.1]: https://github.com/GRoguelon/aws_lambda_runtime/releases/tag/v0.1.1

## [0.1.0] - 2026-08-19

### Added

- `AWS.Lambda.Runtime` — the custom runtime loop: long-polls the Lambda
  Runtime API, dispatches each invocation to your handler within a
  supervised, deadline-bounded task, and reports the result or failure back
  to Lambda without crashing the sandbox.
- `AWS.Lambda.Runtime.API` — a dependency-free `:inets`/`:httpc` client for
  the Lambda Runtime API (`2018-06-01`).
- `AWS.Lambda.Runtime.Context` — per-invocation context assembled from the
  `Lambda-Runtime-*` response headers and the function's environment.
- `AWS.Lambda.Runtime.Handler` — the behaviour your function implements, plus
  resolution of the `_HANDLER` environment variable / compile-time config.
- `AWS.Lambda.Runtime.Application` — the OTP application supervising the
  runtime loop, with a `config :aws_lambda_runtime, start_runtime: false`
  escape hatch for environments (like this library's own test suite) that
  shouldn't start it.
- `AWS.Lambda.Runtime.MixRelease` and `AWS.Lambda.Runtime.Release` — `mix
  release` configuration and steps that package a function for Lambda's
  `provided.al2023` runtime, including the `bootstrap` entrypoint and
  Lambda-tuned `vm.args`/`env.sh`.
- `mix aws_lambda.build` — packages a function's Lambda release inside the
  Elixir builder Docker image and downloads the resulting deployment zip.

[0.1.0]: https://github.com/GRoguelon/aws_lambda_runtime/releases/tag/v0.1.0
