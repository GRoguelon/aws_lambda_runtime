# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
