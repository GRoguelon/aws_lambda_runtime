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

  defmodule StatefulHandler do
    @moduledoc false
    @behaviour AWS.Lambda.Runtime.Handler

    alias AWS.Lambda.Runtime.Request

    @impl true
    def init(info) do
      send(test_pid(), {:init, info})
      {:ok, %{greeting: "hello"}}
    end

    @impl true
    def handle(%Request{method: "GET", path: "/hello", query: query}, _context, state) do
      {:ok, %{greeting: state.greeting, name: query["name"]},
       status: 201, headers: %{"X-Custom" => "1"}, cookies: ["a=b; Path=/"]}
    end

    def handle(%Request{method: "POST", path: "/echo", body: body}, _context, _state) do
      send(test_pid(), {:handled, body})
      {:ok, body}
    end

    def handle(%Request{path: "/text"}, _context, _state) do
      {:ok, "plain", content_type: "text/plain"}
    end

    def handle(%Request{path: "/binary"}, _context, _state) do
      {:ok, <<0, 255>>, content_type: "application/octet-stream"}
    end

    def handle(%Request{path: "/stream"}, _context, _state) do
      {:stream, ["a", "b"], content_type: "text/plain", status: 202}
    end

    def handle(%Request{path: "/nested"}, _context, _state) do
      nested(Process.get(:not_set))
    end

    def handle(%AWS.Lambda.Runtime.Events.SQS{records: messages}, _context, _state) do
      {:retry, Enum.filter(messages, &(&1.body == "fail"))}
    end

    def handle(%{"name" => name}, _context, state) do
      {:ok, "#{state.greeting} #{name}"}
    end

    # Waits to be let go, so invocations overlap.
    def handle(%{"wait" => id}, _context, _state) do
      send(test_pid(), {:waiting, id, self()})

      receive do
        :go -> {:ok, %{id: id, trace_header: AWS.Lambda.Runtime.XRay.trace_header()}}
      end
    end

    def handle(%{"raw" => text}, _context, _state) do
      {:ok, text, content_type: "text/plain"}
    end

    def handle(%{"typo" => _}, _context, _state) do
      {:ok, 1, content_typ: "text/plain"}
    end

    @impl true
    def terminate(reason, state) do
      send(test_pid(), {:terminated, reason, state})
    end

    defp nested(:set), do: :ok

    defp test_pid, do: Application.fetch_env!(:aws_lambda_runtime, :test_pid)
  end

  defmodule FailingInitHandler do
    @moduledoc false
    def init(_info), do: {:error, :no_table}
    def handle(event, _context, _state), do: {:ok, event}
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

  describe "handle/3" do
    setup do
      Application.put_env(:aws_lambda_runtime, :handler, StatefulHandler)
      Application.put_env(:aws_lambda_runtime, :test_pid, self())

      on_exit(fn ->
        Application.delete_env(:aws_lambda_runtime, :test_pid)
        Application.delete_env(:aws_lambda_runtime, :function_url)
        System.delete_env("FUNCTION_URL_INVOKE_MODE")
        :persistent_term.erase({AWS.Lambda.Runtime.Shutdown, :hooks})
      end)
    end

    @tag :capture_log
    test "calls init/1 with the function's environment" do
      System.put_env("AWS_LAMBDA_FUNCTION_NAME", "fn-name")
      System.put_env("AWS_REGION", "eu-west-3")

      on_exit(fn ->
        System.delete_env("AWS_LAMBDA_FUNCTION_NAME")
        System.delete_env("AWS_REGION")
      end)

      {_path, _headers, body} = invoke(%{"name" => "Ada"})

      assert_received {:init, %{function_name: "fn-name", region: "eu-west-3"} = info}
      assert Map.has_key?(info, :memory_limit_mb)
      assert JSON.decode!(body) == "hello Ada"
    end

    @tag :capture_log
    test "answers a payload format 2.0 request in its format" do
      {path, _headers, body} =
        invoke(%{
          "version" => "2.0",
          "rawPath" => "/hello",
          "rawQueryString" => "name=Ada",
          "requestContext" => %{"http" => %{"method" => "GET"}}
        })

      assert path == "/2018-06-01/runtime/invocation/req-h/response"

      assert %{
               "statusCode" => 201,
               "headers" => %{"content-type" => "application/json", "x-custom" => "1"},
               "cookies" => ["a=b; Path=/"],
               "isBase64Encoded" => false,
               "body" => json
             } = JSON.decode!(body)

      assert JSON.decode!(json) == %{"greeting" => "hello", "name" => "Ada"}
    end

    @tag :capture_log
    test "answers a payload format 1.0 request in its format" do
      {_path, _headers, body} =
        invoke(%{
          "httpMethod" => "GET",
          "path" => "/hello",
          "multiValueQueryStringParameters" => %{"name" => ["Ada"]},
          "requestContext" => %{}
        })

      response = JSON.decode!(body)

      assert response["statusCode"] == 201
      assert response["multiValueHeaders"] == %{"set-cookie" => ["a=b; Path=/"]}
      refute Map.has_key?(response, "cookies")
    end

    @tag :capture_log
    test "returns a text body as is, and a binary one in base64" do
      {_path, _headers, text} = invoke(http("GET", "/text"))
      {_path, _headers, binary} = invoke(http("GET", "/binary"))

      assert %{"body" => "plain", "isBase64Encoded" => false, "headers" => headers} =
               JSON.decode!(text)

      assert headers == %{"content-type" => "text/plain"}

      assert %{"body" => encoded, "isBase64Encoded" => true} = JSON.decode!(binary)
      assert Base.decode64!(encoded) == <<0, 255>>
    end

    @tag :capture_log
    test "returns a body with a content type as is to a direct invocation" do
      {_path, _headers, body} = invoke(%{"raw" => "not json"})

      assert body == "not json"
    end

    @tag :capture_log
    test "answers 400 without calling handle/3 when the body can't be decoded" do
      event =
        http("POST", "/echo")
        |> Map.merge(%{"headers" => %{"content-type" => "application/json"}, "body" => "{nope"})

      {_path, _headers, body} = invoke(event)

      assert %{"statusCode" => 400, "body" => message} = JSON.decode!(body)
      assert JSON.decode!(message) == %{"message" => "the request body is not valid JSON"}
      refute_received {:handled, _body}
    end

    @tag :capture_log
    test "streams to a Function URL in RESPONSE_STREAM mode, with the HTTP options" do
      System.put_env("FUNCTION_URL_INVOKE_MODE", "RESPONSE_STREAM")

      {path, headers, body} = invoke(url("GET", "/stream"))

      assert path == "/2018-06-01/runtime/invocation/req-h/response"
      assert headers["content-type"] == "application/vnd.awslambda.http-integration-response"

      [prelude, chunks] = String.split(body, <<0, 0, 0, 0, 0, 0, 0, 0>>, parts: 2)

      assert %{"statusCode" => 202, "headers" => %{"content-type" => "text/plain"}} =
               JSON.decode!(prelude)

      assert chunks == "ab"
    end

    @tag :capture_log
    test "streams {:ok, …} as one chunk to a Function URL in RESPONSE_STREAM mode" do
      System.put_env("FUNCTION_URL_INVOKE_MODE", "response_stream")

      {_path, headers, body} = invoke(url("GET", "/hello", "name=Ada"))

      assert headers["content-type"] == "application/vnd.awslambda.http-integration-response"

      [prelude, chunk] = String.split(body, <<0, 0, 0, 0, 0, 0, 0, 0>>, parts: 2)

      assert %{
               "statusCode" => 201,
               "headers" => %{"content-type" => "application/json", "x-custom" => "1"},
               "cookies" => ["a=b; Path=/"]
             } = JSON.decode!(prelude)

      assert JSON.decode!(chunk) == %{"greeting" => "hello", "name" => "Ada"}
    end

    @tag :capture_log
    test "takes the Function URL's mode from the config, the variable first" do
      Application.put_env(:aws_lambda_runtime, :function_url, :response_stream)

      {_path, headers, _body} = invoke(url("GET", "/text"))
      assert headers["content-type"] == "application/vnd.awslambda.http-integration-response"

      System.put_env("FUNCTION_URL_INVOKE_MODE", "BUFFERED")

      {_path, headers, body} = invoke(url("GET", "/text"))
      assert headers["content-type"] == "application/json"
      assert %{"body" => "plain"} = JSON.decode!(body)
    end

    @tag :capture_log
    test "collects a stream into the envelope of a buffered Function URL or API Gateway" do
      for event <- [url("GET", "/stream"), http("GET", "/stream")] do
        System.put_env("FUNCTION_URL_INVOKE_MODE", "BUFFERED")
        {_path, _headers, buffered_url} = invoke(event)

        assert %{
                 "statusCode" => 202,
                 "headers" => %{"content-type" => "text/plain"},
                 "body" => "ab"
               } = JSON.decode!(buffered_url)
      end

      # API Gateway doesn't read a stream, whatever the URL's mode.
      System.put_env("FUNCTION_URL_INVOKE_MODE", "RESPONSE_STREAM")
      {_path, _headers, api_gateway} = invoke(http("GET", "/stream"))

      assert %{"statusCode" => 202, "body" => "ab"} = JSON.decode!(api_gateway)
    end

    test "reports an unknown FUNCTION_URL_INVOKE_MODE as an init error" do
      System.put_env("FUNCTION_URL_INVOKE_MODE", "STREAMING")
      test_pid = self()

      {_pid, endpoint} =
        FakeRuntimeAPI.start([
          fn {"POST", _path, headers, body} ->
            send(test_pid, {:init_error, headers, body})
            {202, %{}, ""}
          end
        ])

      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

      capture_log(fn ->
        start_runtime!(halt: halt_fun())

        assert_receive {:init_error, headers, body}, 1_000
        assert_receive {:halted, 1}, 1_000

        assert headers["lambda-runtime-function-error-type"] == "ArgumentError"

        assert JSON.decode!(body)["errorMessage"] =~
                 ~s(must be RESPONSE_STREAM or BUFFERED, got: "STREAMING")
      end)
    end

    test "answers 404 when no clause matches a request" do
      log =
        capture_log(fn ->
          {_path, _headers, body} = invoke(http("DELETE", "/nowhere"))

          assert %{"statusCode" => 404, "body" => message} = JSON.decode!(body)
          assert JSON.decode!(message) == %{"message" => "Not Found"}
        end)

      assert log =~ "matches DELETE /nowhere, answering 404"
    end

    test "reports an event no clause matches" do
      log =
        capture_log(fn ->
          {path, headers, body} = invoke(%{"unknown" => 1})

          assert path == "/2018-06-01/runtime/invocation/req-h/error"
          assert headers["lambda-runtime-function-error-type"] == "Runtime.UnhandledEvent"

          assert JSON.decode!(body)["errorMessage"] ==
                   "no clause of AWS.Lambda.RuntimeTest.StatefulHandler.handle/3 matches the event"
        end)

      assert log =~ ~s(matches the event: %{"unknown" => 1})
    end

    @tag :capture_log
    test "reports a function clause error raised further down as a failure" do
      {_path, headers, body} = invoke(http("GET", "/nested"))

      assert headers["lambda-runtime-function-error-type"] == "FunctionClauseError"
      assert [_frame | _frames] = JSON.decode!(body)["stackTrace"]
    end

    @tag :capture_log
    test "reports unknown response options" do
      {_path, headers, body} = invoke(%{"typo" => true})

      assert headers["lambda-runtime-function-error-type"] == "Runtime.InvalidResponse"
      assert JSON.decode!(body)["errorMessage"] =~ "unknown response options: [:content_typ]"
    end

    @tag :capture_log
    test "decodes a service's event and retries the failed records of a batch" do
      records =
        for {id, body} <- [{"m1", "ok"}, {"m2", "fail"}] do
          %{"eventSource" => "aws:sqs", "messageId" => id, "body" => body}
        end

      {path, _headers, body} = invoke(%{"Records" => records})

      assert path == "/2018-06-01/runtime/invocation/req-h/response"
      assert JSON.decode!(body) == %{"batchItemFailures" => [%{"itemIdentifier" => "m2"}]}
    end

    @tag :capture_log
    test "reports a service's event it can't decode without calling handle/3" do
      record = %{"eventSource" => "aws:kinesis", "kinesis" => %{"data" => "%%%"}}

      {_path, headers, body} = invoke(%{"Records" => [record]})

      assert headers["lambda-runtime-function-error-type"] == "Runtime.MalformedEvent"
      assert JSON.decode!(body)["errorMessage"] =~ "is not valid base64"
    end

    @tag :capture_log
    test "emits :telemetry events for init/1 and each invocation" do
      events = [
        [:aws_lambda_runtime, :init, :stop],
        [:aws_lambda_runtime, :invocation, :start],
        [:aws_lambda_runtime, :invocation, :stop],
        [:aws_lambda_runtime, :invocation, :exception]
      ]

      test_pid = self()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {:event, event, measurements, metadata})
      end

      :telemetry.attach_many("runtime-test", events, handler, nil)
      on_exit(fn -> :telemetry.detach("runtime-test") end)

      invoke(%{"Records" => [%{"eventSource" => "aws:sqs", "messageId" => "m1", "body" => "ok"}]})

      assert_received {:event, [:aws_lambda_runtime, :init, :stop], %{duration: _},
                       %{handler: {StatefulHandler, :handle, 3}}}

      assert_received {:event, [:aws_lambda_runtime, :invocation, :start],
                       %{system_time: _, monotonic_time: _}, start}

      assert %{request_id: "req-h", event_type: :sqs, cold_start: true} = start

      assert_received {:event, [:aws_lambda_runtime, :invocation, :stop], %{duration: duration},
                       %{result: :retry, event_type: :sqs}}

      assert duration >= 0

      invoke(http("GET", "/nested"))

      assert_received {:event, [:aws_lambda_runtime, :invocation, :exception], %{duration: _},
                       %{kind: :error, reason: :function_clause, event_type: :request}}
    end

    @tag :capture_log
    test "marks only the environment's first invocation as a cold start" do
      test_pid = self()

      :telemetry.attach(
        "cold-start-test",
        [:aws_lambda_runtime, :invocation, :start],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:cold_start, metadata.cold_start})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("cold-start-test") end)

      dispatch = fn
        {"POST", "/2020-01-01/extension/register", _headers, _body} ->
          {200, %{"lambda-extension-identifier" => "ext"}, "{}"}

        {"GET", "/2020-01-01/extension/event/next", _headers, _body} ->
          {500, %{}, "stop waiting"}

        {"GET", _path, _headers, _body} ->
          {200, %{"lambda-runtime-aws-request-id" => "req-c"}, ~s({"name":"Ada"})}

        {"POST", _path, _headers, _body} ->
          send(test_pid, :posted)
          {202, %{}, ""}
      end

      {_pid, endpoint} = FakeRuntimeAPI.start(List.duplicate(dispatch, 6))

      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)
      :persistent_term.erase({API, :endpoint})

      runtime_pid = start_runtime!(halt: halt_fun())

      assert_receive :posted, 1_000
      assert_receive :posted, 1_000

      stop_runtime(runtime_pid)

      assert_received {:cold_start, true}
      assert_received {:cold_start, false}
    end

    @tag :capture_log
    test "takes AWS_LAMBDA_MAX_CONCURRENCY invocations at once, each with its trace header" do
      System.put_env("AWS_LAMBDA_MAX_CONCURRENCY", "2")
      System.delete_env("_X_AMZN_TRACE_ID")
      on_exit(fn -> System.delete_env("AWS_LAMBDA_MAX_CONCURRENCY") end)

      test_pid = self()
      invocations = :counters.new(1, [])

      dispatch = fn
        {"POST", "/2020-01-01/extension/register", _headers, _body} ->
          {200, %{"lambda-extension-identifier" => "ext"}, "{}"}

        {"GET", "/2020-01-01/extension/event/next", _headers, _body} ->
          {500, %{}, "stop waiting"}

        {"GET", _path, _headers, _body} ->
          :counters.add(invocations, 1, 1)
          n = :counters.get(invocations, 1)

          {200,
           %{
             "lambda-runtime-aws-request-id" => "req-#{n}",
             "lambda-runtime-trace-id" => "Root=1-00000000-00000000000000000000000#{n};Sampled=0"
           }, ~s({"wait":#{n}})}

        {"POST", path, _headers, body} ->
          send(test_pid, {:posted, path, body})
          {202, %{}, ""}
      end

      # Two spare steps: a poller that has posted asks for its next invocation
      # at once, and must not take the other's post's place.
      {_pid, endpoint} = FakeRuntimeAPI.start(List.duplicate(dispatch, 8))

      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)
      :persistent_term.erase({API, :endpoint})

      runtime_pid = start_runtime!(halt: halt_fun())

      # Both are being handled before either is let go.
      assert_receive {:waiting, first, first_pid}, 1_000
      assert_receive {:waiting, second, second_pid}, 1_000
      assert Enum.sort([first, second]) == [1, 2]

      send(first_pid, :go)
      send(second_pid, :go)

      for _invocation <- 1..2 do
        assert_receive {:posted, "/2018-06-01/runtime/invocation/req-" <> n, body}, 1_000
        n = String.trim_trailing(n, "/response")

        assert %{"id" => id, "trace_header" => header} = JSON.decode!(body)
        assert "#{id}" == n
        assert header == "Root=1-00000000-00000000000000000000000#{n};Sampled=0"
      end

      # Several invocations at once can't share it.
      assert System.get_env("_X_AMZN_TRACE_ID") == nil

      stop_runtime(runtime_pid)
    end

    @tag :capture_log
    test "registers terminate/2 as a shutdown function, with the state" do
      invoke(%{"name" => "Ada"})

      AWS.Lambda.Runtime.Shutdown.run(fn -> :ok end)

      assert_received {:terminated, :shutdown, %{greeting: "hello"}}
    end

    test "reports an init/1 error as an init error" do
      Application.put_env(:aws_lambda_runtime, :handler, FailingInitHandler)
      test_pid = self()

      {_pid, endpoint} =
        FakeRuntimeAPI.start([
          fn {"POST", path, headers, body} ->
            send(test_pid, {:init_error, path, headers, body})
            {202, %{}, ""}
          end
        ])

      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)

      capture_log(fn ->
        start_runtime!(halt: halt_fun())

        assert_receive {:init_error, path, headers, body}, 1_000
        assert_receive {:halted, 1}, 1_000

        assert path == "/2018-06-01/runtime/init/error"
        assert headers["lambda-runtime-function-error-type"] == "Runtime.InitError"
        assert JSON.decode!(body)["errorMessage"] == "init/1 failed: :no_table"
      end)
    end

    defp url(method, path, query \\ "") do
      method
      |> http(path)
      |> Map.put("rawQueryString", query)
      |> put_in(["requestContext", "domainName"], "abc123.lambda-url.eu-west-3.on.aws")
    end

    defp http(method, path) do
      %{
        "version" => "2.0",
        "rawPath" => path,
        "requestContext" => %{"http" => %{"method" => method}}
      }
    end

    # Serves one invocation of `event`, answering the extension's requests,
    # which arrive in any order, and returns what the runtime posted.
    defp invoke(event) do
      test_pid = self()

      dispatch = fn
        {"POST", "/2020-01-01/extension/register", _headers, _body} ->
          {200, %{"lambda-extension-identifier" => "ext"}, "{}"}

        {"GET", "/2020-01-01/extension/event/next", _headers, _body} ->
          {500, %{}, "stop waiting"}

        {"GET", _path, _headers, _body} ->
          {200, %{"lambda-runtime-aws-request-id" => "req-h"}, JSON.encode!(event)}

        {"POST", path, headers, body} ->
          send(test_pid, {:posted, path, headers, body})
          {202, %{}, ""}
      end

      {_pid, endpoint} = FakeRuntimeAPI.start(List.duplicate(dispatch, 4))

      # A test may invoke more than once, each time with its own fake API.
      System.put_env("AWS_LAMBDA_RUNTIME_API", endpoint)
      :persistent_term.erase({API, :endpoint})
      :persistent_term.erase({AWS.Lambda.Runtime.Shutdown, :hooks})

      runtime_pid = start_runtime!(halt: halt_fun())

      assert_receive {:posted, path, headers, body}, 1_000

      stop_runtime(runtime_pid)

      {path, headers, body}
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
