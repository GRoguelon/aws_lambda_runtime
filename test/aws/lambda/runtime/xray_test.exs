defmodule AWS.Lambda.Runtime.XRayTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AWS.Lambda.Runtime.XRay
  alias Support.FakeXRayDaemon

  @root "1-5759e988-bd862e3fe1be46a994272793"
  @parent "53995c3f42cd8ad8"
  @sampled "Root=#{@root};Parent=#{@parent};Sampled=1;Lineage=a87bd80c:1"

  setup do
    {socket, address} = FakeXRayDaemon.start()

    System.put_env("AWS_XRAY_DAEMON_ADDRESS", address)
    System.put_env("_X_AMZN_TRACE_ID", @sampled)

    on_exit(fn ->
      System.delete_env("AWS_XRAY_DAEMON_ADDRESS")
      System.delete_env("_X_AMZN_TRACE_ID")
    end)

    %{daemon: socket}
  end

  describe "subsegment/3" do
    test "sends a subsegment of the invocation's segment", %{daemon: daemon} do
      before = System.os_time(:microsecond) / 1_000_000

      assert XRay.subsegment("work", fn -> :result end) == :result

      document = FakeXRayDaemon.receive_document(daemon)

      assert %{
               "name" => "work",
               "trace_id" => @root,
               "parent_id" => @parent,
               "type" => "subsegment",
               "id" => id,
               "start_time" => start_time,
               "end_time" => end_time
             } = document

      assert id =~ ~r/\A[0-9a-f]{16}\z/
      assert before <= start_time and start_time <= end_time
      refute Map.has_key?(document, "fault")
    end

    test "nests a subsegment in the open one", %{daemon: daemon} do
      XRay.subsegment("outer", fn ->
        XRay.subsegment("inner", fn -> :ok end)
      end)

      inner = FakeXRayDaemon.receive_document(daemon)
      outer = FakeXRayDaemon.receive_document(daemon)

      assert inner["name"] == "inner"
      assert inner["parent_id"] == outer["id"]
      assert outer["parent_id"] == @parent
    end

    test "takes the invocation's trace header from its process first", %{daemon: daemon} do
      XRay.put_trace_header(
        "Root=1-00000000-000000000000000000000001;Parent=0000000000000002;Sampled=1"
      )

      XRay.subsegment("work", fn -> :ok end)

      assert %{
               "trace_id" => "1-00000000-000000000000000000000001",
               "parent_id" => "0000000000000002"
             } = FakeXRayDaemon.receive_document(daemon)
    end

    test "sends nothing when the invocation isn't sampled", %{daemon: daemon} do
      System.put_env("_X_AMZN_TRACE_ID", "Root=#{@root};Parent=#{@parent};Sampled=0")

      assert XRay.subsegment("work", fn -> XRay.subsegment("inner", fn -> 1 end) end) == 1

      FakeXRayDaemon.refute_document(daemon)
    end

    test "sends nothing outside of an invocation", %{daemon: daemon} do
      System.delete_env("_X_AMZN_TRACE_ID")

      assert XRay.subsegment("work", fn -> :result end) == :result

      FakeXRayDaemon.refute_document(daemon)
    end

    test "records an exception as a fault and reraises it", %{daemon: daemon} do
      assert_raise RuntimeError, "boom", fn ->
        XRay.subsegment("work", fn -> raise "boom" end)
      end

      document = FakeXRayDaemon.receive_document(daemon)

      assert document["fault"] == true
      assert %{"working_directory" => _cwd, "exceptions" => [exception]} = document["cause"]
      assert %{"id" => _id, "type" => "RuntimeError", "message" => "boom"} = exception
      assert [%{"label" => label, "path" => path, "line" => line} | _frames] = exception["stack"]
      assert label =~ "AWS.Lambda.Runtime.XRayTest."
      assert path =~ "xray_test.exs"
      assert is_integer(line)
    end

    test "records a throw and an exit, and lets them through", %{daemon: daemon} do
      assert catch_throw(XRay.subsegment("work", fn -> throw(:thrown) end)) == :thrown
      assert catch_exit(XRay.subsegment("work", fn -> exit(:gone) end)) == :gone

      assert %{"cause" => %{"exceptions" => [throw]}} = FakeXRayDaemon.receive_document(daemon)
      assert %{"type" => "Throw", "message" => ":thrown"} = throw

      assert %{"cause" => %{"exceptions" => [exit]}} = FakeXRayDaemon.receive_document(daemon)
      assert %{"type" => "Exit", "message" => ":gone"} = exit
    end

    test "records the namespace, annotations, metadata and fields", %{daemon: daemon} do
      XRay.subsegment("query", fn -> :ok end,
        namespace: :remote,
        annotations: %{user_id: 42, admin: false, plan: :pro},
        metadata: %{rows: [1, 2]},
        sql: %{url: "postgresql://db/app", sanitized_query: "SELECT 1"}
      )

      document = FakeXRayDaemon.receive_document(daemon)

      assert document["namespace"] == "remote"
      assert document["annotations"] == %{"user_id" => 42, "admin" => false, "plan" => "pro"}
      assert document["metadata"] == %{"default" => %{"rows" => [1, 2]}}
      assert document["sql"] == %{"url" => "postgresql://db/app", "sanitized_query" => "SELECT 1"}
    end

    test "attaches to the given trace header", %{daemon: daemon} do
      header = "Root=1-00000000-000000000000000000000000;Parent=0000000000000001;Sampled=1"

      XRay.subsegment("outer", fn ->
        Task.await(
          Task.async(fn -> XRay.subsegment("task", fn -> :ok end, trace_header: header) end)
        )
      end)

      task = FakeXRayDaemon.receive_document(daemon)

      assert task["trace_id"] == "1-00000000-000000000000000000000000"
      assert task["parent_id"] == "0000000000000001"
    end

    test "sends nothing when the given trace header isn't sampled", %{daemon: daemon} do
      XRay.subsegment("work", fn -> :ok end, trace_header: nil)

      FakeXRayDaemon.refute_document(daemon)
    end

    test "rejects an unknown option" do
      assert_raise ArgumentError, fn ->
        XRay.subsegment("work", fn -> :ok end, nmespace: "aws")
      end
    end
  end

  describe "begin_subsegment/2 and end_subsegment/1" do
    test "merge the HTTP fields given at the start and at the end", %{daemon: daemon} do
      XRay.begin_subsegment("GET example.com",
        namespace: "remote",
        http: %{request: %{method: "GET", url: "https://example.com"}}
      )

      XRay.end_subsegment(http: %{response: %{status: 200, content_length: 12}})

      document = FakeXRayDaemon.receive_document(daemon)

      assert document["http"] == %{
               "request" => %{"method" => "GET", "url" => "https://example.com"},
               "response" => %{"status" => 200, "content_length" => 12}
             }

      refute Map.has_key?(document, "error")
      refute Map.has_key?(document, "fault")
    end

    test "flag an error, a throttle or a fault from the response status", %{daemon: daemon} do
      for status <- [404, 429, 503] do
        XRay.begin_subsegment("call")
        XRay.end_subsegment(http: %{response: %{status: status}})
      end

      assert %{"error" => true} = not_found = FakeXRayDaemon.receive_document(daemon)
      refute Map.has_key?(not_found, "throttle")
      assert %{"error" => true, "throttle" => true} = FakeXRayDaemon.receive_document(daemon)
      assert %{"fault" => true} = unavailable = FakeXRayDaemon.receive_document(daemon)
      refute Map.has_key?(unavailable, "error")
    end

    test "end_subsegment/1 does nothing when no subsegment is open", %{daemon: daemon} do
      assert XRay.end_subsegment() == :ok

      FakeXRayDaemon.refute_document(daemon)
    end
  end

  describe "put_annotation/2 and put_metadata/2" do
    test "add to the open subsegment", %{daemon: daemon} do
      XRay.subsegment("work", fn ->
        XRay.put_annotation(:status, "done")
        XRay.put_metadata("result", %{"count" => 3})
      end)

      document = FakeXRayDaemon.receive_document(daemon)

      assert document["annotations"] == %{"status" => "done"}
      assert document["metadata"] == %{"default" => %{"result" => %{"count" => 3}}}
    end

    test "do nothing outside of a subsegment" do
      assert XRay.put_annotation(:status, "done") == :ok
      assert XRay.put_metadata(:result, 3) == :ok
    end
  end

  describe "update_subsegment/1" do
    test "merges into the open subsegment before it ends", %{daemon: daemon} do
      XRay.subsegment("call", fn ->
        XRay.update_subsegment(http: %{response: %{status: 503}}, annotations: %{retried: true})
      end)

      assert %{
               "fault" => true,
               "http" => %{"response" => %{"status" => 503}},
               "annotations" => %{"retried" => true}
             } = FakeXRayDaemon.receive_document(daemon)
    end

    test "does nothing outside of a subsegment" do
      assert XRay.update_subsegment(http: %{response: %{status: 200}}) == :ok
    end
  end

  describe "trace_header/0" do
    test "is the invocation's outside of a subsegment" do
      assert XRay.trace_header() == @sampled
    end

    test "has the open subsegment as its parent", %{daemon: daemon} do
      header = XRay.subsegment("work", fn -> XRay.trace_header() end)

      %{"id" => id} = FakeXRayDaemon.receive_document(daemon)

      assert header == "Root=#{@root};Parent=#{id};Sampled=1;Lineage=a87bd80c:1"
    end

    test "is the invocation's when it isn't sampled" do
      header = "Root=#{@root};Parent=#{@parent};Sampled=0"
      System.put_env("_X_AMZN_TRACE_ID", header)

      assert XRay.subsegment("work", fn -> XRay.trace_header() end) == header
    end

    test "is nil outside of an invocation" do
      System.delete_env("_X_AMZN_TRACE_ID")

      assert XRay.trace_header() == nil
    end
  end

  describe "the daemon" do
    test "is reached at the UDP address of a tcp/udp pair", %{daemon: daemon} do
      address = System.get_env("AWS_XRAY_DAEMON_ADDRESS")
      System.put_env("AWS_XRAY_DAEMON_ADDRESS", "tcp:127.0.0.1:1 udp:#{address}")

      XRay.subsegment("work", fn -> :ok end)

      assert %{"name" => "work"} = FakeXRayDaemon.receive_document(daemon)
    end

    test "doesn't get a subsegment that cannot be encoded", %{daemon: daemon} do
      log =
        capture_log(fn ->
          assert XRay.subsegment("work", fn -> :ok end, metadata: %{pid: self()}) == :ok
        end)

      assert log =~ "could not send the X-Ray segment"
      FakeXRayDaemon.refute_document(daemon)
    end

    test "doesn't get a subsegment over 64KB", %{daemon: daemon} do
      log =
        capture_log(fn ->
          XRay.subsegment("work", fn -> :ok end, metadata: %{blob: String.duplicate("a", 70_000)})
        end)

      assert log =~ "too_large"
      FakeXRayDaemon.refute_document(daemon)
    end

    test "logs an invalid address" do
      System.put_env("AWS_XRAY_DAEMON_ADDRESS", "nowhere")

      log = capture_log(fn -> XRay.subsegment("work", fn -> :ok end) end)

      assert log =~ "invalid_daemon_address"
    end
  end
end
