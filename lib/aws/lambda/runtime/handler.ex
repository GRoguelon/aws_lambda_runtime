defmodule AWS.Lambda.Runtime.Handler do
  @moduledoc """
  Behaviour implemented by your function, plus resolution of the `_HANDLER`
  environment variable that Lambda sets from the function's *Handler* setting.

  ## Accepted handler strings

      MyLambda.Handler                  # calls MyLambda.Handler.handle_event/2
      MyLambda.Handler.handle_event     # explicit function
      Elixir.MyLambda.Handler.process   # the Elixir. prefix is optional

  The rule is simple: if the last dot-separated segment starts with a lowercase
  letter or underscore it is taken as the function name, otherwise the whole
  string is the module and `handle_event/2` is assumed.

  A compile-time override can be set with

      config :aws_lambda_runtime, :handler, {MyLambda.Handler, :handle_event}

  which takes precedence over `_HANDLER` and is handy for local testing.

  ## Return values

    * `{:ok, payload}` — `payload` is JSON encoded and returned to the caller
    * `{:error, reason}` — reported to Lambda as a function error
    * anything else — encoded and returned as the payload

  Raising, exiting or throwing is caught by the runtime and reported as a
  function error without taking down the VM, so the sandbox stays warm.
  """

  ## Behaviours

  @callback handler(event :: term(), context :: term()) ::
              {:ok, term()} | {:error, term()} | term()

  ## Module attributes

  @default_function :handler

  ## Public functions

  @doc """
  Resolves the configured handler into a `{module, function}` pair, raising if
  it cannot be loaded. Called once during initialisation so that a bad handler
  surfaces as an init error rather than failing every invocation.
  """
  def resolve!() do
    spec =
      Application.get_env(:aws_lambda_runtime, :handler) ||
        System.get_env("_HANDLER") ||
        raise ArgumentError,
              "no handler configured: set the function's Handler property or " <>
                "config :aws_lambda_runtime, :handler"

    {module, function} = parse!(spec)

    Code.ensure_loaded!(module)

    unless function_exported?(module, function, 2) do
      raise ArgumentError,
            "#{inspect(module)}.#{function}/2 is not exported — the handler must " <>
              "accept the event and the invocation context"
    end

    {module, function}
  end

  @doc """
  Parses a handler spec (a module, a `{module, function}` pair, or a handler
  string as described in the moduledoc) into a `{module, function}` pair.
  """
  def parse!(module) when is_atom(module) do
    {module, @default_function}
  end

  def parse!({module, function}) when is_atom(module) and is_atom(function) do
    {module, function}
  end

  def parse!(spec) when is_binary(spec) do
    segments =
      spec
      |> String.trim()
      |> String.split(".", trim: true)
      |> drop_elixir_prefix()

    case Enum.split(segments, -1) do
      {[], []} ->
        raise ArgumentError, "handler string is empty"

      {module_segments, [last]} ->
        if function_segment?(last) do
          if module_segments == [] do
            raise ArgumentError, "handler #{inspect(spec)} is missing a module name"
          end

          {Module.concat(module_segments), String.to_atom(last)}
        else
          {Module.concat(segments), @default_function}
        end
    end
  end

  ## Private functions

  defp drop_elixir_prefix(["Elixir" | rest]) when rest != [] do
    rest
  end

  defp drop_elixir_prefix(segments) do
    segments
  end

  defp function_segment?(<<char, _rest::binary>>) when char in ?a..?z or char == ?_ do
    true
  end

  defp function_segment?(_segment) do
    false
  end
end
