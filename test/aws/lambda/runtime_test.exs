defmodule AWS.Lambda.RuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AWS.Lambda.Runtime.API
  alias Support.FakeRuntimeAPI

  defmodule EchoHandler do
    @moduledoc false
    @behaviour AWS.Lambda.Runtime.Handler

    @impl AWS.Lambda.Runtime.Handler
    def handler(%{"mode" => "error"}, _context), do: {:error, "nope"}
    def handler(%{"mode" => "raise"}, _context), do: raise("boom")
    def handler(%{"mode" => "throw"}, _context), do: throw(:thrown)
    def handler(%{"mode" => "exit"}, _context), do: exit(:gone)

    def handler(%{"mode" => "stream"}, _context) do
      {:stream, Stream.map(["a", "", "b"], & &1), content_type: "text/plain"}
    end

    def handler(%{"mode" => "stream_http"}, _context) do
      {:stream, ["hi"], http: [status: 201, headers: %{"x-a" => "b"}, cookies: ["c=d"]]}
    end

    def handler(%{"mode" => "stream_raise"}, _context) do
      {:stream,
       Stream.map([1, 2], fn
         1 -> "ok"
         2 -> raise "mid-stream"
       end)}
    end

    def handler(%{"mode" => "stream_typo"}, _context) do
      {:stream, ["never sent"], content_typ: "text/plain"}
    end

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

  @tag :capture_log
  test "exits when the next invocation is answered with an error status" do
    {_pid, endpoint} =
      FakeRuntimeAPI.start([
        fn {"GET", _path, _headers, _body} -> {500, %{}, "container error"} end
      ])

    System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

    runtime_pid = start_runtime!(halt: halt_fun())

    assert_receive {:halted, 1}, 1_000
    assert_receive {:EXIT, ^runtime_pid, :normal}, 1_000
  end

  @tag :capture_log
  test "exits when the Runtime API stays unreachable" do
    # No steps: the fake server closes its socket, so every connection fails.
    {_pid, endpoint} = FakeRuntimeAPI.start([])

    System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

    runtime_pid = start_runtime!(halt: halt_fun())

    assert_receive {:halted, 1}, 2_000
    assert_receive {:EXIT, ^runtime_pid, :normal}, 1_000
  end

  @tag :capture_log
  test "exits when posting the response is answered with a container error" do
    {_pid, endpoint} =
      FakeRuntimeAPI.start([
        fn {"GET", _path, _headers, _body} ->
          {200, %{"lambda-runtime-aws-request-id" => "req-5"}, ~s({"mode":"ok"})}
        end,
        fn {"POST", _path, _headers, _body} -> {500, %{}, "container error"} end
      ])

    System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

    runtime_pid = start_runtime!(halt: halt_fun())

    assert_receive {:halted, 1}, 1_000

    stop_runtime(runtime_pid)
  end

  describe "shutdown" do
    setup do
      on_exit(fn -> :persistent_term.erase({AWS.Lambda.Runtime.Shutdown, :hooks}) end)
    end

    test "registers an internal extension when a shutdown function is registered" do
      test_pid = self()
      AWS.Lambda.Runtime.Shutdown.register(fn -> :ok end)

      # The extension's and the runtime's requests may arrive in any order.
      dispatch = fn
        {"POST", "/2020-01-01/extension/register" = path, headers, body} ->
          send(test_pid, {:registered, path, headers, body})
          {200, %{"lambda-extension-identifier" => "ext-1"}, ~s({"functionName":"f"})}

        {"GET", "/2020-01-01/extension/event/next", headers, _body} ->
          send(test_pid, {:extension_waiting, headers})
          {500, %{}, "stop waiting"}

        {"GET", _path, _headers, _body} ->
          {200, %{"lambda-runtime-aws-request-id" => "req-x"}, ~s({"mode":"ok"})}

        {"POST", _path, _headers, body} ->
          send(test_pid, {:posted, body})
          {202, %{}, ""}
      end

      {_pid, endpoint} = FakeRuntimeAPI.start(List.duplicate(dispatch, 4))

      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

      log =
        capture_log(fn ->
          runtime_pid = start_runtime!()

          assert_receive {:registered, path, headers, body}, 1_000
          assert path == "/2020-01-01/extension/register"
          assert headers["lambda-extension-name"] == "aws_lambda_runtime"
          assert JSON.decode!(body) == %{"events" => []}

          assert_receive {:extension_waiting, headers}, 1_000
          assert headers["lambda-extension-identifier"] == "ext-1"

          assert_receive {:posted, _body}, 1_000

          stop_runtime(runtime_pid)
        end)

      assert log =~ "the shutdown extension stopped waiting for events"
    end

    test "goes on without the extension when its registration fails" do
      test_pid = self()
      AWS.Lambda.Runtime.Shutdown.register(fn -> :ok end)

      {_pid, endpoint} =
        FakeRuntimeAPI.start([
          fn {"POST", _path, _headers, _body} -> {500, %{}, "nope"} end,
          fn {"GET", _path, _headers, _body} ->
            {200, %{"lambda-runtime-aws-request-id" => "req-y"}, ~s({"mode":"ok"})}
          end,
          fn {"POST", _path, _headers, body} ->
            send(test_pid, {:posted, body})
            {202, %{}, ""}
          end
        ])

      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

      log =
        capture_log(fn ->
          runtime_pid = start_runtime!()
          assert_receive {:posted, _body}, 1_000
          stop_runtime(runtime_pid)
        end)

      assert log =~ "could not register for SIGTERM"
    end
  end

  describe "handler failures" do
    test "logs a raised exception once, without the task's crash report" do
      log =
        capture_log(fn ->
          {headers, _body} = invoke_and_capture(~s({"mode":"raise"}), "error")
          assert headers["lambda-runtime-function-error-type"] == "RuntimeError"
        end)

      assert length(String.split(log, "(RuntimeError) boom")) == 2
      refute log =~ "terminating"
    end

    @tag :capture_log
    test "reports a thrown value as Handler.Throw" do
      {headers, body} = invoke_and_capture(~s({"mode":"throw"}), "error")

      assert headers["lambda-runtime-function-error-type"] == "Handler.Throw"
      assert JSON.decode!(body)["errorMessage"] == ":thrown"
    end

    @tag :capture_log
    test "reports an exit as Handler.Exit" do
      {headers, body} = invoke_and_capture(~s({"mode":"exit"}), "error")

      assert headers["lambda-runtime-function-error-type"] == "Handler.Exit"
      assert JSON.decode!(body)["errorMessage"] == ":gone"
    end
  end

  describe "streaming" do
    test "streams the chunks with the streaming headers" do
      {headers, body} = invoke_and_capture(~s({"mode":"stream"}), "response")

      assert headers["lambda-runtime-function-response-mode"] == "streaming"
      assert headers["transfer-encoding"] == "chunked"
      assert headers["content-type"] == "text/plain"
      refute Map.has_key?(headers, "lambda-runtime-function-error-type")
      assert body == "ab"
    end

    test "prepends the Function URL prelude" do
      {headers, body} = invoke_and_capture(~s({"mode":"stream_http"}), "response")

      assert headers["content-type"] == "application/vnd.awslambda.http-integration-response"
      assert [prelude, "hi"] = :binary.split(body, <<0, 0, 0, 0, 0, 0, 0, 0>>)

      assert JSON.decode!(prelude) == %{
               "statusCode" => 201,
               "headers" => %{"x-a" => "b", "content-type" => "application/octet-stream"},
               "cookies" => ["c=d"]
             }
    end

    @tag :capture_log
    test "reports an error raised mid-stream in the trailers" do
      {headers, body} = invoke_and_capture(~s({"mode":"stream_raise"}), "response")

      assert body == "ok"
      assert headers["lambda-runtime-function-error-type"] == "RuntimeError"

      error = headers["lambda-runtime-function-error-body"] |> Base.decode64!() |> JSON.decode!()
      assert error["errorType"] == "RuntimeError"
      assert error["errorMessage"] == "mid-stream"
    end

    @tag :capture_log
    test "reports invalid stream options as an error before streaming" do
      {headers, body} = invoke_and_capture(~s({"mode":"stream_typo"}), "error")

      assert headers["lambda-runtime-function-error-type"] == "ArgumentError"
      assert JSON.decode!(body)["errorMessage"] =~ "content_typ"
    end
  end

  # Serves one invocation of `event`, then returns the headers and body the
  # runtime posted to /response or /error (`kind`).
  defp invoke_and_capture(event, kind) do
    test_pid = self()

    {_pid, endpoint} =
      FakeRuntimeAPI.start([
        fn {"GET", _path, _headers, _body} ->
          {200, %{"lambda-runtime-aws-request-id" => "req-s"}, event}
        end,
        fn {"POST", path, headers, body} ->
          send(test_pid, {:posted, path, headers, body})
          {202, %{}, ""}
        end
      ])

    System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

    runtime_pid = start_runtime!(halt: halt_fun())

    assert_receive {:posted, path, headers, body}, 1_000
    assert path == "/2018-06-01/runtime/invocation/req-s/#{kind}"

    stop_runtime(runtime_pid)

    {headers, body}
  end

  defp start_runtime!(opts \\ []) do
    {:ok, pid} = AWS.Lambda.Runtime.start_link(opts)
    pid
  end

  # Stands in for System.halt/1, which would stop the test VM.
  defp halt_fun do
    test_pid = self()
    fn status -> send(test_pid, {:halted, status}) end
  end

  defp stop_runtime(pid) do
    Process.exit(pid, :kill)
    assert_receive {:EXIT, ^pid, :killed}, 1_000
  end
end
