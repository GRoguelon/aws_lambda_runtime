defmodule AWS.Lambda.Runtime.Handler do
  @moduledoc """
  Behaviour implemented by your function, plus resolution of the `_HANDLER`
  environment variable that Lambda sets from the function's *Handler* setting.

  ## Accepted handler strings

      MyLambda.Handler                  # calls MyLambda.Handler.handler/2
      MyLambda.Handler.process          # calls MyLambda.Handler.process/2
      Elixir.MyLambda.Handler.process   # the Elixir. prefix is optional

  The rule is simple: if the last dot-separated segment starts with a lowercase
  letter or underscore it is taken as the function name, otherwise the whole
  string is the module and `handler/2` is assumed.

  The handler can also be set in the application config, as a module, a
  `{module, function}` pair or a handler string:

      config :aws_lambda_runtime, :handler, {MyLambda.Handler, :process}

  The config takes precedence over `_HANDLER`, so the function's *Handler*
  setting is then ignored. Handy for local testing.

  ## Return values

    * `{:ok, payload}` — `payload` is JSON encoded and returned to the caller
    * `{:error, reason}` — reported to Lambda as a function error
    * `{:stream, chunks}` or `{:stream, chunks, opts}` — streams the response,
      see below
    * anything else — encoded and returned as the payload

  Raising, exiting or throwing is caught by the runtime and reported as a
  function error without taking down the VM, so the sandbox stays warm.

  ## Streaming

  `chunks` is any enumerable of iodata, such as a `Stream`. It is consumed
  lazily and each element is sent to the caller as soon as it is produced;
  empty elements are skipped. The whole stream must be sent before the
  invocation deadline.

      def handler(%{"count" => count}, _context) do
        {:stream, Stream.map(1..count, &"data: \#{&1}\\n\\n"),
         content_type: "text/event-stream",
         http: [headers: %{"cache-control" => "no-cache"}]}
      end

  Options:

    * `:content_type` — of the stream. Defaults to `"application/octet-stream"`.
    * `:http` — for a Function URL in `RESPONSE_STREAM` mode, the status
      (`:status`, default `200`), `:headers` (a map) and `:cookies` (a list)
      of its HTTP response. Without it, the chunks are sent as they are, as
      `InvokeWithResponseStream` callers expect.
    * `:send_timeout` — in milliseconds, how long writing one chunk may stall
      before the stream is abandoned. Defaults to `30_000`.

  Once the first chunk is sent the response is committed: an exception raised
  while producing the rest is sent in the stream's error trailers, which
  Lambda passes on to the caller.

  Lambda only streams to callers that ask for it — a Function URL configured
  with `RESPONSE_STREAM` or the `InvokeWithResponseStream` API; others get the
  whole response once it is complete.
  """

  ## Behaviours

  @callback handler(event :: term(), context :: term()) ::
              {:ok, term()}
              | {:error, term()}
              | {:stream, Enumerable.t()}
              | {:stream, Enumerable.t(), keyword()}
              | term()

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
