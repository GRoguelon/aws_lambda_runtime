defmodule AWS.Lambda.Runtime.HandlerTest do
  use ExUnit.Case, async: false

  alias AWS.Lambda.Runtime.Handler

  defmodule TestHandler do
    @moduledoc false
    @behaviour Handler

    @impl Handler
    def handler(event, _context), do: {:ok, event}

    def not_a_handler(_event, _context), do: :nope
  end

  describe "parse!/1" do
    test "a bare module defaults to handler/2" do
      assert Handler.parse!(TestHandler) == {TestHandler, :handler}
    end

    test "a {module, function} pair is returned as-is" do
      assert Handler.parse!({TestHandler, :not_a_handler}) == {TestHandler, :not_a_handler}
    end

    test "a module string defaults to handler/2" do
      assert Handler.parse!("AWS.Lambda.Runtime.HandlerTest.TestHandler") ==
               {TestHandler, :handler}
    end

    test "a module string with the Elixir. prefix is accepted" do
      assert Handler.parse!("Elixir.AWS.Lambda.Runtime.HandlerTest.TestHandler") ==
               {TestHandler, :handler}
    end

    test "a module.function string picks the explicit function" do
      assert Handler.parse!("AWS.Lambda.Runtime.HandlerTest.TestHandler.not_a_handler") ==
               {TestHandler, :not_a_handler}
    end

    test "raises on an empty string" do
      assert_raise ArgumentError, ~r/empty/, fn -> Handler.parse!("") end
    end

    test "raises when a function segment has no module" do
      assert_raise ArgumentError, ~r/missing a module name/, fn -> Handler.parse!("handler") end
    end
  end

  describe "resolve!/0" do
    setup do
      on_exit(fn ->
        Application.delete_env(:aws_lambda_runtime, :handler)
        System.delete_env("_HANDLER")
      end)

      :ok
    end

    test "prefers the compile-time config over _HANDLER" do
      Application.put_env(:aws_lambda_runtime, :handler, {TestHandler, :handler})
      System.put_env("_HANDLER", "SomeOther.Module")

      assert Handler.resolve!() == {TestHandler, :handler}
    end

    test "falls back to the _HANDLER environment variable" do
      System.put_env("_HANDLER", "AWS.Lambda.Runtime.HandlerTest.TestHandler")

      assert Handler.resolve!() == {TestHandler, :handler}
    end

    test "raises when nothing is configured" do
      assert_raise ArgumentError, ~r/no handler configured/, fn -> Handler.resolve!() end
    end

    test "raises when the resolved function is not exported with arity 2" do
      Application.put_env(:aws_lambda_runtime, :handler, {TestHandler, :missing})

      assert_raise ArgumentError, ~r/is not exported/, fn -> Handler.resolve!() end
    end
  end
end
