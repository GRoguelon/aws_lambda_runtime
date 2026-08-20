import Config

# Individual tests exercise AWS.Lambda.Runtime.start_link/1 directly against a
# fake Runtime API, so the application itself must not start the loop —
# otherwise every `mix test` run would immediately crash-loop on a missing
# AWS_LAMBDA_RUNTIME_API.
config :aws_lambda_runtime, start_runtime: false
