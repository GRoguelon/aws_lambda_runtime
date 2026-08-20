defmodule AWS.Lambda.Runtime.ContextTest do
  use ExUnit.Case, async: false

  alias AWS.Lambda.Runtime.Context

  describe "from_headers/1" do
    test "maps Lambda-Runtime-* headers onto the struct" do
      headers = %{
        "lambda-runtime-aws-request-id" => "req-1",
        "lambda-runtime-deadline-ms" => "12345",
        "lambda-runtime-invoked-function-arn" => "arn:aws:lambda:eu-west-1:1:function:f",
        "lambda-runtime-trace-id" => "Root=1-abc",
        "lambda-runtime-client-context" => ~s({"client":{"app_title":"demo"}}),
        "lambda-runtime-cognito-identity" => ~s({"cognitoIdentityId":"eu:123"})
      }

      context = Context.from_headers(headers)

      assert context.request_id == "req-1"
      assert context.deadline_ms == 12345
      assert context.invoked_function_arn == "arn:aws:lambda:eu-west-1:1:function:f"
      assert context.trace_id == "Root=1-abc"
      assert context.client_context == %{"client" => %{"app_title" => "demo"}}
      assert context.identity == %{"cognitoIdentityId" => "eu:123"}
    end

    test "leaves optional fields nil when headers are absent" do
      context = Context.from_headers(%{})

      assert context.request_id == nil
      assert context.deadline_ms == nil
      assert context.client_context == nil
      assert context.identity == nil
    end

    test "leaves client_context/identity nil when the JSON is malformed" do
      context =
        Context.from_headers(%{"lambda-runtime-client-context" => "not json"})

      assert context.client_context == nil
    end

    test "reads the function environment from the system environment" do
      System.put_env("AWS_LAMBDA_FUNCTION_NAME", "my-function")
      System.put_env("AWS_LAMBDA_FUNCTION_VERSION", "3")
      System.put_env("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "256")
      System.put_env("AWS_LAMBDA_LOG_GROUP_NAME", "/aws/lambda/my-function")
      System.put_env("AWS_LAMBDA_LOG_STREAM_NAME", "stream-1")

      on_exit(fn ->
        System.delete_env("AWS_LAMBDA_FUNCTION_NAME")
        System.delete_env("AWS_LAMBDA_FUNCTION_VERSION")
        System.delete_env("AWS_LAMBDA_FUNCTION_MEMORY_SIZE")
        System.delete_env("AWS_LAMBDA_LOG_GROUP_NAME")
        System.delete_env("AWS_LAMBDA_LOG_STREAM_NAME")
      end)

      context = Context.from_headers(%{})

      assert context.function_name == "my-function"
      assert context.function_version == "3"
      assert context.memory_limit_mb == 256
      assert context.log_group == "/aws/lambda/my-function"
      assert context.log_stream == "stream-1"
    end
  end

  describe "remaining_time_ms/1" do
    test "returns :infinity when there is no deadline" do
      assert Context.remaining_time_ms(%Context{deadline_ms: nil}) == :infinity
    end

    test "returns the milliseconds left before the deadline" do
      deadline = System.system_time(:millisecond) + 5_000

      remaining = Context.remaining_time_ms(%Context{deadline_ms: deadline})

      assert remaining in 4_000..5_000
    end

    test "never returns a negative number for a deadline in the past" do
      deadline = System.system_time(:millisecond) - 5_000

      assert Context.remaining_time_ms(%Context{deadline_ms: deadline}) == 0
    end
  end
end
