defmodule AWS.Lambda.Runtime.XRay.TelemetryTest do
  use ExUnit.Case, async: false

  alias AWS.Lambda.Runtime.XRay
  alias AWS.Lambda.Runtime.XRay.Telemetry
  alias Support.FakeXRayDaemon

  defmodule Repo do
    @moduledoc false
    def __adapter__, do: Ecto.Adapters.Postgres
  end

  @root "1-5759e988-bd862e3fe1be46a994272793"
  @parent "53995c3f42cd8ad8"

  setup do
    {socket, address} = FakeXRayDaemon.start()

    System.put_env("AWS_XRAY_DAEMON_ADDRESS", address)
    System.put_env("_X_AMZN_TRACE_ID", "Root=#{@root};Parent=#{@parent};Sampled=1")

    on_exit(fn ->
      Telemetry.detach()
      System.delete_env("AWS_XRAY_DAEMON_ADDRESS")
      System.delete_env("_X_AMZN_TRACE_ID")
    end)

    %{daemon: socket}
  end

  describe "spans" do
    test "are recorded as subsegments named after their prefix", %{daemon: daemon} do
      :ok = Telemetry.attach(spans: [[:my_app, :work]])

      assert :telemetry.span([:my_app, :work], %{}, fn -> {:result, %{}} end) == :result

      assert %{"name" => "my_app.work", "parent_id" => @parent, "type" => "subsegment"} =
               document = FakeXRayDaemon.receive_document(daemon)

      assert document["start_time"] <= document["end_time"]
      refute Map.has_key?(document, "fault")
    end

    test "take their name and namespace from the options", %{daemon: daemon} do
      :ok =
        Telemetry.attach(
          spans: [{[:my_app, :job], name: &("job " <> &1.job), namespace: "remote"}]
        )

      :telemetry.span([:my_app, :job], %{job: "Mailer"}, fn -> {:ok, %{}} end)

      assert %{"name" => "job Mailer", "namespace" => "remote"} =
               FakeXRayDaemon.receive_document(daemon)
    end

    test "record an exception as a fault", %{daemon: daemon} do
      :ok = Telemetry.attach(spans: [[:my_app, :work]])

      assert_raise RuntimeError, fn ->
        :telemetry.span([:my_app, :work], %{}, fn -> raise "boom" end)
      end

      assert %{"fault" => true, "cause" => %{"exceptions" => [exception]}} =
               FakeXRayDaemon.receive_document(daemon)

      assert %{"type" => "RuntimeError", "message" => "boom"} = exception
    end

    test "nest in the open subsegment, and the other way around", %{daemon: daemon} do
      :ok = Telemetry.attach(spans: [[:my_app, :work]])

      XRay.subsegment("outer", fn ->
        :telemetry.span([:my_app, :work], %{}, fn ->
          {XRay.subsegment("inner", fn -> :ok end), %{}}
        end)
      end)

      inner = FakeXRayDaemon.receive_document(daemon)
      span = FakeXRayDaemon.receive_document(daemon)
      outer = FakeXRayDaemon.receive_document(daemon)

      assert inner["parent_id"] == span["id"]
      assert span["parent_id"] == outer["id"]
    end
  end

  describe "ecto" do
    test "records a query, back-dated by its total time", %{daemon: daemon} do
      :ok = Telemetry.attach(ecto: [:my_app, :repo])

      total = System.convert_time_unit(20, :millisecond, :native)
      query = System.convert_time_unit(15, :millisecond, :native)

      :telemetry.execute(
        [:my_app, :repo, :query],
        %{total_time: total, query_time: query, queue_time: total - query},
        %{
          repo: Repo,
          query: ~s(SELECT u0."id" FROM "users" AS u0 WHERE u0."id" = $1),
          params: [42],
          source: "users",
          result: {:ok, %{}}
        }
      )

      document = FakeXRayDaemon.receive_document(daemon)

      assert document["name"] == inspect(Repo)
      assert document["namespace"] == "remote"
      assert document["parent_id"] == @parent

      assert document["sql"] == %{
               "sanitized_query" => ~s(SELECT u0."id" FROM "users" AS u0 WHERE u0."id" = $1),
               "database_type" => "PostgreSQL"
             }

      assert document["metadata"] == %{
               "default" => %{
                 "source" => "users",
                 "query_time_ms" => 15.0,
                 "queue_time_ms" => 5.0
               }
             }

      assert_in_delta document["end_time"] - document["start_time"], 0.020, 0.005
    end

    test "records an error as a fault", %{daemon: daemon} do
      :ok = Telemetry.attach(ecto: [[:my_app, :repo], [:my_app, :read_repo]])

      :telemetry.execute([:my_app, :read_repo, :query], %{total_time: 1}, %{
        repo: :not_a_repo,
        query: "SELECT 1",
        result: {:error, %RuntimeError{message: "connection refused"}}
      })

      document = FakeXRayDaemon.receive_document(daemon)

      assert document["fault"] == true
      assert document["sql"] == %{"sanitized_query" => "SELECT 1"}

      assert [%{"type" => "RuntimeError", "message" => "connection refused"}] =
               document["cause"]["exceptions"]
    end
  end

  describe "finch" do
    @request %{
      scheme: :https,
      host: "api.example.com",
      port: 443,
      method: "GET",
      path: "/users",
      query: "token=secret"
    }

    setup do
      :ok = Telemetry.attach(finch: true)
    end

    test "records a request with its URL and response status", %{daemon: daemon} do
      request(%{@request | port: 8443}, {:ok, %{status: 200}})

      document = FakeXRayDaemon.receive_document(daemon)

      assert document["name"] == "api.example.com"
      assert document["namespace"] == "remote"

      assert document["http"] == %{
               "request" => %{"method" => "GET", "url" => "https://api.example.com:8443/users"},
               "response" => %{"status" => 200}
             }

      refute inspect(document) =~ "secret"
    end

    test "flags the response status", %{daemon: daemon} do
      request(@request, {:ok, %{status: 503}})

      assert %{"fault" => true, "http" => %{"request" => %{"url" => url}}} =
               FakeXRayDaemon.receive_document(daemon)

      assert url == "https://api.example.com/users"
    end

    test "takes the status of a streamed response from the receive event", %{daemon: daemon} do
      :telemetry.execute([:finch, :request, :start], %{system_time: System.system_time()}, %{
        request: @request
      })

      :telemetry.execute([:finch, :recv, :stop], %{duration: 1}, %{
        request: @request,
        status: 404,
        headers: []
      })

      :telemetry.execute([:finch, :request, :stop], %{duration: 1}, %{
        request: @request,
        result: {:ok, {:req_accumulator}}
      })

      assert %{"error" => true, "http" => %{"response" => %{"status" => 404}}} =
               FakeXRayDaemon.receive_document(daemon)
    end

    test "records an error result as a fault", %{daemon: daemon} do
      request(@request, {:error, %RuntimeError{message: "closed"}})

      assert %{"fault" => true, "cause" => %{"exceptions" => [%{"message" => "closed"}]}} =
               FakeXRayDaemon.receive_document(daemon)
    end

    test "records an exception as a fault", %{daemon: daemon} do
      :telemetry.execute([:finch, :request, :start], %{system_time: System.system_time()}, %{
        request: @request
      })

      :telemetry.execute([:finch, :request, :exception], %{duration: 1}, %{
        request: @request,
        kind: :exit,
        reason: :timeout,
        stacktrace: []
      })

      assert %{"fault" => true, "cause" => %{"exceptions" => [%{"type" => "Exit"}]}} =
               FakeXRayDaemon.receive_document(daemon)
    end

    defp request(request, result) do
      :telemetry.execute([:finch, :request, :start], %{system_time: System.system_time()}, %{
        request: request
      })

      :telemetry.execute([:finch, :request, :stop], %{duration: 1}, %{
        request: request,
        result: result
      })
    end
  end

  describe "attach/1 and detach/0" do
    test "record nothing when the invocation isn't sampled", %{daemon: daemon} do
      System.put_env("_X_AMZN_TRACE_ID", "Root=#{@root};Parent=#{@parent};Sampled=0")
      :ok = Telemetry.attach(spans: [[:my_app, :work]], ecto: [:my_app, :repo])

      :telemetry.span([:my_app, :work], %{}, fn ->
        :telemetry.execute([:my_app, :repo, :query], %{total_time: 1}, %{query: "SELECT 1"})
        {:ok, %{}}
      end)

      FakeXRayDaemon.refute_document(daemon)
    end

    test "attach/1 refuses a handler already attached" do
      :ok = Telemetry.attach(finch: true)

      assert Telemetry.attach(finch: true) == {:error, :already_exists}
    end

    test "detach/0 detaches every handler", %{daemon: daemon} do
      :ok = Telemetry.attach(spans: [[:my_app, :work]], finch: true)

      assert Telemetry.detach() == :ok

      :telemetry.span([:my_app, :work], %{}, fn -> {:ok, %{}} end)

      FakeXRayDaemon.refute_document(daemon)
      assert :telemetry.list_handlers([]) |> Enum.filter(&match?({Telemetry, _}, &1.id)) == []
    end
  end
end
