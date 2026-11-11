import Config

# Releases run on Lambda, where AWS_LAMBDA_RUNTIME_API is set, so the
# application starts the runtime loop.
config :aws_lambda_runtime, start_runtime: true
