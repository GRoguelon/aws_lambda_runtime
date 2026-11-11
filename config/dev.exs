import Config

# The runtime loop polls the AWS_LAMBDA_RUNTIME_API that only Lambda provides,
# so it must not start locally — otherwise `iex -S mix` would immediately
# crash-loop.
config :aws_lambda_runtime, start_runtime: false
