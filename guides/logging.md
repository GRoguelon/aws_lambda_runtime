# Logging

The runtime follows the function's logging configuration, which Lambda
passes to it as `AWS_LAMBDA_LOG_FORMAT` and `AWS_LAMBDA_LOG_LEVEL`:

```sh
aws lambda update-function-configuration --function-name elixir-hello \
  --logging-config LogFormat=JSON,ApplicationLogLevel=INFO
```

- **Level:** in both log formats, `Logger`'s level is, by priority:
  1. `AWS_LAMBDA_LOG_LEVEL` (`TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR` or
     `FATAL`; `TRACE` is `Logger`'s `:debug`), so verbosity can be changed in
     the function's configuration without a new deployment. A warning is
     logged at start when it overrides a different
     `config :logger, level: ...`;
  2. `config :logger, level: ...`;
  3. `:info` in the release, rather than `Logger`'s default `:debug`, which
     `iex -S mix` and tests keep.
- **JSON format:** each log entry is written as one line of JSON, with its
  `timestamp`, `level`, `message`, the `requestId` of the invocation, and the
  entry's `Logger` metadata. A multi-line message, such as a stack trace,
  stays a single CloudWatch Logs event.

```json
{"level":"INFO","message":"two\nlines","mfa":"MyApp.Handler.handle/3","requestId":"8f5…","timestamp":"2026-11-13T15:49:52.683Z","user_id":42}
```

In the `Text` format, entries are written by `Logger`'s default formatter.
