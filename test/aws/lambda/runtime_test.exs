defmodule AWS.Lambda.RuntimeTest do
  use ExUnit.Case, async: false

  alias AWS.Lambda.Runtime.API
  alias Support.FakeRuntimeAPI

  defmodule EchoHandler do
    @moduledoc false
    @behaviour AWS.Lambda.Runtime.Handler

    @impl AWS.Lambda.Runtime.Handler
    def handler(%{"mode" => "error"}, _context), do: {:error, "nope"}
    def handler(%{"mode" => "raise"}, _context), do: raise("boom")

    def handler(event, context) do
      {:ok, %{"echo" => event, "request_id" => context.request_id}}
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    :persistent_term.erase({API, :endpoint})
    Application.put_env(:aws_lambda_runtime, :handler, {EchoHandler, :handler})

    on_exit(fn ->
      Application.delete_env(:aws_lambda_runtime, :handler)
      System.delete_env("AWS_LAMBDA_RUNTIME_API")
      :persistent_term.erase({API, :endpoint})
    end)

    :ok
  end

  test "processes a successful invocation and posts the response" do
    test_pid = self()

    {_pid, endpoint} =
      FakeRuntimeAPI.start([
        fn {"GET", _path, _headers, _body} ->
          {200, %{"lambda-runtime-aws-request-id" => "req-1"}, ~s({"mode":"ok","value":42})}
        end,
        fn {"POST", path, _headers, body} ->
          assert path == "/2018-06-01/runtime/invocation/req-1/response"
          send(test_pid, {:posted, body})
          {202, %{}, ""}
        end
      ])

    System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

    runtime_pid = start_runtime!()

    assert_receive {:posted, body}, 1_000
    assert {:ok, decoded} = JSON.decode(body)
    assert decoded == %{"echo" => %{"mode" => "ok", "value" => 42}, "request_id" => "req-1"}

    stop_runtime(runtime_pid)
  end

  test "reports a handler error" do
    test_pid = self()

    {_pid, endpoint} =
      FakeRuntimeAPI.start([
        fn {"GET", _path, _headers, _body} ->
          {200, %{"lambda-runtime-aws-request-id" => "req-2"}, ~s({"mode":"error"})}
        end,
        fn {"POST", path, headers, body} ->
          assert path == "/2018-06-01/runtime/invocation/req-2/error"
          assert headers["lambda-runtime-function-error-type"] == "Handler.Error"
          send(test_pid, {:posted, body})
          {202, %{}, ""}
        end
      ])

    System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

    runtime_pid = start_runtime!()

    assert_receive {:posted, body}, 1_000
    assert {:ok, decoded} = JSON.decode(body)
    assert decoded["errorType"] == "Handler.Error"
    assert decoded["errorMessage"] == "nope"

    stop_runtime(runtime_pid)
  end

  test "reports a raised exception from the handler" do
    test_pid = self()

    {_pid, endpoint} =
      FakeRuntimeAPI.start([
        fn {"GET", _path, _headers, _body} ->
          {200, %{"lambda-runtime-aws-request-id" => "req-3"}, ~s({"mode":"raise"})}
        end,
        fn {"POST", path, headers, body} ->
          assert path == "/2018-06-01/runtime/invocation/req-3/error"
          assert headers["lambda-runtime-function-error-type"] == "RuntimeError"
          send(test_pid, {:posted, body})
          {202, %{}, ""}
        end
      ])

    System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

    runtime_pid = start_runtime!()

    assert_receive {:posted, body}, 1_000
    assert {:ok, decoded} = JSON.decode(body)
    assert decoded["errorType"] == "RuntimeError"
    assert decoded["errorMessage"] == "boom"

    stop_runtime(runtime_pid)
  end

  test "reports malformed JSON as Runtime.MalformedEvent without invoking the handler" do
    test_pid = self()

    {_pid, endpoint} =
      FakeRuntimeAPI.start([
        fn {"GET", _path, _headers, _body} ->
          {200, %{"lambda-runtime-aws-request-id" => "req-4"}, "not json"}
        end,
        fn {"POST", path, headers, body} ->
          assert path == "/2018-06-01/runtime/invocation/req-4/error"
          assert headers["lambda-runtime-function-error-type"] == "Runtime.MalformedEvent"
          send(test_pid, {:posted, body})
          {202, %{}, ""}
        end
      ])

    System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

    runtime_pid = start_runtime!()

    assert_receive {:posted, _body}, 1_000

    stop_runtime(runtime_pid)
  end

  defp start_runtime! do
    {:ok, pid} = AWS.Lambda.Runtime.start_link([])
    pid
  end

  defp stop_runtime(pid) do
    Process.exit(pid, :kill)
    assert_receive {:EXIT, ^pid, :killed}, 1_000
  end
end
