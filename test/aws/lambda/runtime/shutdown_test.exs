defmodule AWS.Lambda.Runtime.ShutdownTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AWS.Lambda.Runtime.Shutdown

  setup do
    :persistent_term.erase({Shutdown, :hooks})
    on_exit(fn -> :persistent_term.erase({Shutdown, :hooks}) end)
  end

  describe "register/1" do
    test "marks shutdown as wanted" do
      refute Shutdown.registered?()

      assert Shutdown.register(fn -> :ok end) == :ok

      assert Shutdown.registered?()
    end
  end

  describe "run/1" do
    test "calls the functions in order, then stop" do
      test_pid = self()

      Shutdown.register(fn -> send(test_pid, :first) end)
      Shutdown.register(fn -> send(test_pid, :second) end)

      log = capture_log(fn -> Shutdown.run(fn -> send(test_pid, :stopped) end) end)

      assert log =~ "SIGTERM received, shutting down"
      assert {:messages, [:first, :second, :stopped]} = Process.info(self(), :messages)
    end

    test "logs a failing function and calls the next one" do
      test_pid = self()

      Shutdown.register(fn -> raise "flush failed" end)
      Shutdown.register(fn -> throw(:oops) end)
      Shutdown.register(fn -> send(test_pid, :still_called) end)

      log = capture_log(fn -> Shutdown.run(fn -> send(test_pid, :stopped) end) end)

      assert log =~ "shutdown function failed: ** (RuntimeError) flush failed"
      assert log =~ "shutdown function failed: ** (throw) :oops"
      assert_received :still_called
      assert_received :stopped
    end
  end

  describe "the SIGTERM handler" do
    test "replaces the VM's default one" do
      handlers = :gen_event.which_handlers(:erl_signal_server)

      assert Shutdown in handlers
      refute :erl_signal_handler in handlers
    end

    test "is only installed once" do
      assert Shutdown.install() == :ok

      assert Enum.count(:gen_event.which_handlers(:erl_signal_server), &(&1 == Shutdown)) == 1
    end

    @tag :capture_log
    test "runs the functions on SIGTERM, outside of the signal server" do
      test_pid = self()
      Shutdown.register(fn -> send(test_pid, {:hook, self()}) end)

      assert {:ok, _stop} = Shutdown.handle_event(:sigterm, fn -> send(test_pid, :stopped) end)

      assert_receive {:hook, hook_pid}, 1_000
      assert_receive :stopped, 1_000
      refute hook_pid == self()
    end

    test "ignores other signals" do
      stop = fn -> :ok end

      assert Shutdown.handle_event(:sighup, stop) == {:ok, stop}
    end
  end
end
