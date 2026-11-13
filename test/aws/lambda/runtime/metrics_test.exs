defmodule AWS.Lambda.Runtime.MetricsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AWS.Lambda.Runtime.Metrics

  describe "emit/3" do
    test "writes one EMF line with the metrics, dimensions and properties" do
      line =
        emitted(fn ->
          Metrics.emit("MyApp", %{"OrderTotal" => {42.5, :none}, "Items" => 3, "Waits" => [1, 2]},
            dimensions: %{channel: :web},
            properties: %{"orderId" => 7}
          )
        end)

      assert %{
               "_aws" => %{
                 "Timestamp" => timestamp,
                 "CloudWatchMetrics" => [
                   %{"Namespace" => "MyApp", "Dimensions" => [["channel"]], "Metrics" => metrics}
                 ]
               },
               "channel" => "web",
               "orderId" => 7,
               "OrderTotal" => 42.5,
               "Items" => 3,
               "Waits" => [1, 2]
             } = line

      assert_in_delta timestamp, System.system_time(:millisecond), 5_000

      assert Enum.sort_by(metrics, & &1["Name"]) == [
               %{"Name" => "Items"},
               %{"Name" => "OrderTotal", "Unit" => "None"},
               %{"Name" => "Waits"}
             ]
    end

    test "publishes without dimensions" do
      assert %{"_aws" => %{"CloudWatchMetrics" => [%{"Dimensions" => [[]]}]}} =
               emitted(fn -> Metrics.emit("MyApp", %{"Hits" => 1}) end)
    end

    test "takes a unit as a string" do
      assert %{"_aws" => %{"CloudWatchMetrics" => [%{"Metrics" => [metric]}]}} =
               emitted(fn -> Metrics.emit("MyApp", %{"Size" => {12, "Kilobytes"}}) end)

      assert metric == %{"Name" => "Size", "Unit" => "Kilobytes"}
    end

    test "adds the invocation's request ID" do
      line =
        emitted(fn ->
          Logger.metadata(request_id: "req-1")
          Metrics.emit("MyApp", %{"Hits" => 1})
        end)

      assert line["requestId"] == "req-1"
    end

    test "refuses what CloudWatch wouldn't accept" do
      assert_raise ArgumentError, ~r/must be a number/, fn ->
        Metrics.emit("MyApp", %{"Hits" => "1"})
      end

      assert_raise ArgumentError, ~r/must be numbers/, fn ->
        Metrics.emit("MyApp", %{"Hits" => [1, "2"]})
      end

      assert_raise ArgumentError, ~r/unknown CloudWatch unit :lightyears/, fn ->
        Metrics.emit("MyApp", %{"Distance" => {1, :lightyears}})
      end

      assert_raise ArgumentError, ~r/at most 100 metrics/, fn ->
        Metrics.emit("MyApp", Map.new(1..101, &{"m#{&1}", &1}))
      end
    end
  end

  describe "count/4 and timing/4" do
    test "count/4 publishes a count" do
      assert %{"Orders" => 2, "_aws" => %{"CloudWatchMetrics" => [%{"Metrics" => [metric]}]}} =
               emitted(fn -> Metrics.count("MyApp", "Orders", 2) end)

      assert metric == %{"Name" => "Orders", "Unit" => "Count"}
    end

    test "timing/4 publishes how long the function took and returns its result" do
      line =
        emitted(fn ->
          assert Metrics.timing("MyApp", "Work", fn -> Process.sleep(20) && :done end) == :done
        end)

      assert line["Work"] >= 20

      assert [%{"Name" => "Work", "Unit" => "Milliseconds"}] =
               get_in(line, ["_aws", "CloudWatchMetrics", Access.at(0), "Metrics"])
    end
  end

  defp emitted(fun) do
    output = capture_io(fun)

    assert [line] = String.split(output, "\n", trim: true)

    JSON.decode!(line)
  end
end
