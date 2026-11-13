defmodule AWS.Lambda.Runtime.LogFormatterTest do
  use ExUnit.Case, async: true

  alias AWS.Lambda.Runtime.LogFormatter

  describe "format/2" do
    test "writes the fixed fields as one line of JSON" do
      line = format(%{msg: {:string, "hello"}, meta: %{request_id: "req-1"}})

      assert String.ends_with?(line, "\n")
      assert %{"level" => "INFO", "message" => "hello", "requestId" => "req-1"} = decode(line)
      assert decode(line)["timestamp"] == "2026-11-13T15:41:03.123Z"
    end

    test "omits requestId outside an invocation" do
      refute Map.has_key?(decode(format(%{msg: {:string, "boot"}})), "requestId")
    end

    test "keeps a multi-line message on one line" do
      line = format(%{msg: {:string, "boom\n    at line 1\n    at line 2"}})

      assert [_json, ""] = String.split(line, "\n")
      assert decode(line)["message"] == "boom\n    at line 1\n    at line 2"
    end

    test "renders format strings and reports like Logger does" do
      assert decode(format(%{msg: {~c"~p items", [3]}}))["message"] == "3 items"
      assert decode(format(%{msg: {:report, %{a: 1}}}))["message"] == "[a: 1]"
    end

    test "adds the metadata, without the VM's internal keys" do
      meta = %{
        module: MyApp.Handler,
        function: "handler/2",
        file: "lib/my_app/handler.ex",
        line: 12,
        user_id: 42,
        tenant: :acme,
        pid: self(),
        mfa: {MyApp.Handler, :handler, 2},
        gl: Process.group_leader()
      }

      fields = decode(format(%{msg: {:string, "hi"}, meta: meta}))

      assert fields["module"] == "MyApp.Handler"
      assert fields["function"] == "handler/2"
      assert fields["file"] == "lib/my_app/handler.ex"
      assert fields["line"] == 12
      assert fields["user_id"] == 42
      assert fields["tenant"] == "acme"
      assert fields["mfa"] == "MyApp.Handler.handler/2"
      refute Map.has_key?(fields, "pid")
      refute Map.has_key?(fields, "gl")
    end

    test "writes an Erlang mfa like Elixir does" do
      fields = decode(format(%{msg: {:string, "hi"}, meta: %{mfa: {:lists, :map, 2}}}))

      assert fields["mfa"] == ":lists.map/2"
    end

    test "inspects metadata JSON can't represent" do
      fields =
        decode(format(%{msg: {:string, "hi"}, meta: %{ref: {:a, 1}, path: ~c"lib/x.ex"}}))

      assert fields["ref"] == "{:a, 1}"
      assert fields["path"] == "lib/x.ex"
    end

    test "maps the levels to Lambda's" do
      for {level, expected} <- [
            debug: "DEBUG",
            info: "INFO",
            notice: "INFO",
            warning: "WARN",
            error: "ERROR",
            critical: "FATAL",
            alert: "FATAL",
            emergency: "FATAL"
          ] do
        assert decode(format(%{level: level, msg: {:string, "x"}}))["level"] == expected
      end
    end
  end

  # 2026-11-13T15:41:03.123456Z
  @time 1_794_584_463_123_456

  defp format(event) do
    event = Map.merge(%{level: :info, meta: %{}}, event)
    event = put_in(event, [:meta, :time], @time)

    event |> LogFormatter.format(%{}) |> IO.iodata_to_binary()
  end

  defp decode(line) do
    line |> String.trim_trailing("\n") |> JSON.decode!()
  end
end
