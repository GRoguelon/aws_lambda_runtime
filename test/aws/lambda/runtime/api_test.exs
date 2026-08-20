defmodule AWS.Lambda.Runtime.APITest do
  use ExUnit.Case, async: false

  alias AWS.Lambda.Runtime.API
  alias Support.FakeRuntimeAPI

  setup do
    :persistent_term.erase({API, :endpoint})

    on_exit(fn ->
      System.delete_env("AWS_LAMBDA_RUNTIME_API")
      :persistent_term.erase({API, :endpoint})
    end)

    :ok
  end

  describe "setup/0" do
    test "starts the httpc profile and caches the endpoint" do
      {_pid, endpoint} = FakeRuntimeAPI.start([])
      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

      assert :ok = API.setup()
    end

    test "raises when AWS_LAMBDA_RUNTIME_API is not set" do
      System.delete_env("AWS_LAMBDA_RUNTIME_API")

      assert_raise RuntimeError, ~r/AWS_LAMBDA_RUNTIME_API is not set/, fn ->
        API.setup()
      end
    end
  end

  describe "next_invocation/0" do
    test "returns the headers and raw body on 200" do
      {_pid, endpoint} =
        FakeRuntimeAPI.start([
          fn {"GET", path, _headers, _body} ->
            assert path == "/2018-06-01/runtime/invocation/next"

            {200,
             %{
               "lambda-runtime-aws-request-id" => "req-1",
               "lambda-runtime-deadline-ms" => "1000"
             }, ~s({"hello":"world"})}
          end
        ])

      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)
      assert :ok = API.setup()

      assert {:ok, headers, body} = API.next_invocation()
      assert headers["lambda-runtime-aws-request-id"] == "req-1"
      assert body == ~s({"hello":"world"})
    end

    test "returns an error on an unexpected status" do
      {_pid, endpoint} =
        FakeRuntimeAPI.start([
          fn {"GET", _path, _headers, _body} -> {500, %{}, "boom"} end
        ])

      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)
      assert :ok = API.setup()

      assert {:error, {:unexpected_status, 500, "boom"}} = API.next_invocation()
    end

    test "returns an error when the endpoint is unreachable" do
      System.put_env("AWS_LAMBDA_RUNTIME_API", "127.0.0.1:1")
      assert :ok = API.setup()

      assert {:error, _reason} = API.next_invocation()
    end
  end

  describe "invocation_response/2" do
    test "posts the body to the response path" do
      {_pid, endpoint} =
        FakeRuntimeAPI.start([
          fn {"POST", path, _headers, body} ->
            assert path == "/2018-06-01/runtime/invocation/req-1/response"
            assert body == ~s({"ok":true})

            {202, %{}, ""}
          end
        ])

      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)
      assert :ok = API.setup()

      assert :ok = API.invocation_response("req-1", ~s({"ok":true}))
    end
  end

  describe "invocation_error/3" do
    test "posts the payload with the error type header" do
      {_pid, endpoint} =
        FakeRuntimeAPI.start([
          fn {"POST", path, headers, body} ->
            assert path == "/2018-06-01/runtime/invocation/req-1/error"
            assert headers["lambda-runtime-function-error-type"] == "Handler.Error"
            assert body =~ "boom"

            {202, %{}, ""}
          end
        ])

      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)
      assert :ok = API.setup()

      assert :ok =
               API.invocation_error("req-1", %{"errorMessage" => "boom"}, "Handler.Error")
    end
  end

  describe "init_error/2" do
    test "posts the payload to the init error path" do
      {_pid, endpoint} =
        FakeRuntimeAPI.start([
          fn {"POST", path, headers, body} ->
            assert path == "/2018-06-01/runtime/init/error"
            assert headers["lambda-runtime-function-error-type"] == "Runtime.InitError"
            assert body =~ "boom"

            {202, %{}, ""}
          end
        ])

      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)
      assert :ok = API.setup()

      assert :ok = API.init_error(%{"errorMessage" => "boom"}, "Runtime.InitError")
    end
  end
end
