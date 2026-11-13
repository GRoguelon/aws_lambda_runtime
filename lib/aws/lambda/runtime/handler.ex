defmodule AWS.Lambda.Runtime.Handler do
  @moduledoc """
  Behaviour implemented by your function, plus resolution of the handler to
  call.

      defmodule MyLambda.Handler do
        @behaviour AWS.Lambda.Runtime.Handler

        alias AWS.Lambda.Runtime.Request

        @impl true
        def init(_info) do
          {:ok, %{table: System.fetch_env!("TABLE")}}
        end

        @impl true
        def handle(%Request{method: "GET", path: "/users/" <> id}, _context, state) do
          {:ok, MyLambda.Users.get(state.table, id)}
        end

        def handle(%Request{method: "POST", path: "/users", body: %{"name" => name}}, _context, state) do
          {:ok, MyLambda.Users.create(state.table, name), status: 201}
        end

        def handle(%{"name" => name}, _context, _state) do
          {:ok, %{greeting: "hello \#{name}"}}
        end

        @impl true
        def terminate(_reason, _state) do
          MyLambda.Metrics.flush()
        end
      end

  ## Callbacks

    * `c:init/1`, optional, runs once per execution environment, during
      Lambda's init phase, before the first invocation. Its state is passed
      to every `c:handle/3`, which can't change it. It runs in the runtime's
      process: start long-lived processes from the function's application
      instead, so they aren't linked to it.
    * `c:handle/3` handles each invocation. The event is:
        * an `AWS.Lambda.Runtime.Request` for an HTTP request from a
          Function URL or API Gateway, with its body already decoded;
        * the payload, decoded from JSON, for anything else: a direct
          invocation, or an event from SQS, S3, EventBridge…
    * `c:terminate/2`, optional, is called with `:shutdown` when Lambda shuts
      the execution environment down. Implementing it is enough for Lambda
      to warn the runtime: see `AWS.Lambda.Runtime.Shutdown`.

  `c:handler/2`, which receives the event decoded from JSON as is, without
  state, is still called when the module doesn't define `c:handle/3`.

  ## Return values

    * `{:ok, body}` - `body` is JSON encoded and returned to the caller.
    * `{:ok, body, opts}` - the same, with these options:
        * `:status`, `:headers` (a map), `:cookies` (a list of `Set-Cookie`
          values) - of the HTTP response, for an `AWS.Lambda.Runtime.Request`.
          Ignored otherwise.
        * `:content_type` - a binary `body` is then returned as is rather than
          JSON encoded.
    * `{:stream, chunks}` or `{:stream, chunks, opts}` - streams the response,
      see below.
    * `{:error, reason}` - reported to Lambda as a function error.
    * anything else - JSON encoded and returned to the caller.

  For an `AWS.Lambda.Runtime.Request`, the response is encoded as the
  Function URL or API Gateway expects it: status `200`, a `content-type`
  of `application/json` unless given, and a body that isn't UTF-8 encoded in
  base64.

  Raising, exiting or throwing is caught by the runtime and reported as a
  function error without taking down the VM, so the sandbox stays warm.

  ## Streaming

  `chunks` is any enumerable of iodata, such as a `Stream`. It is consumed
  lazily and each element is sent to the caller as soon as it is produced;
  empty elements are skipped. The whole stream must be sent before the
  invocation deadline.

      def handle(%Request{path: "/events"}, _context, _state) do
        {:stream, Stream.map(1..5, &"data: \#{&1}\\n\\n"),
         content_type: "text/event-stream", headers: %{"cache-control" => "no-cache"}}
      end

  Options:

    * `:content_type` - of the stream. Defaults to `"application/octet-stream"`.
    * `:status`, `:headers`, `:cookies` - of the HTTP response, for an
      `AWS.Lambda.Runtime.Request` from a Function URL in `RESPONSE_STREAM`
      mode. Ignored otherwise.
    * `:http` - the same three as a keyword list, the only way to set them
      from `c:handler/2`. Without it, `c:handler/2`'s chunks are sent as they
      are, as `InvokeWithResponseStream` callers expect.
    * `:send_timeout` - in milliseconds, how long writing one chunk may stall
      before the stream is abandoned. Defaults to `30_000`.

  Once the first chunk is sent the response is committed: an exception raised
  while producing the rest is sent in the stream's error trailers, which
  Lambda passes on to the caller.

  Lambda only streams to callers that ask for it - a Function URL configured
  with `RESPONSE_STREAM` or the `InvokeWithResponseStream` API; others get the
  whole response once it is complete.

  ## Accepted handler strings

      MyLambda.Handler                  # calls handle/3, or handler/2
      MyLambda.Handler.process          # calls process/3, or process/2
      Elixir.MyLambda.Handler.process   # the Elixir. prefix is optional

  The rule is simple: if the last dot-separated segment starts with a lowercase
  letter or underscore it is taken as the function name, otherwise the whole
  string is the module.

  ## Where the handler comes from

  The first one set of:

    1. the `:handler` option of `AWS.Lambda.Runtime.Release.lambda/1`, built
       into the release:

           releases: [lambda: fn -> AWS.Lambda.Runtime.Release.lambda(handler: MyLambda.Handler) end]

    2. the application config, as a module, a `{module, function}` pair or a
       handler string. Handy for local testing:

           config :aws_lambda_runtime, :handler, {MyLambda.Handler, :process}

    3. the function's *Handler* setting, which Lambda passes as `_HANDLER`.
       It lets one package serve several functions, each with its own
       handler.

  Lambda requires a *Handler* setting even when the handler comes from the
  release or the config: any value then does.
  """

  alias AWS.Lambda.Runtime.Context
  alias AWS.Lambda.Runtime.Request

  ## Types

  @typedoc "What the function's environment is, given to `c:init/1`."
  @type info :: %{
          function_name: String.t() | nil,
          function_version: String.t() | nil,
          memory_limit_mb: pos_integer() | nil,
          region: String.t() | nil,
          log_group: String.t() | nil,
          log_stream: String.t() | nil
        }

  @type result ::
          {:ok, term()}
          | {:ok, term(), keyword()}
          | {:error, term()}
          | {:stream, Enumerable.t()}
          | {:stream, Enumerable.t(), keyword()}
          | term()

  ## Behaviours

  @doc "Builds the state given to every `c:handle/3`. See the moduledoc."
  @callback init(info()) :: {:ok, state :: term()} | {:error, reason :: term()}

  @doc "Handles an invocation. See the moduledoc."
  @callback handle(event :: Request.t() | term(), Context.t(), state :: term()) :: result()

  @doc "Called when Lambda shuts the execution environment down. See the moduledoc."
  @callback terminate(reason :: :shutdown, state :: term()) :: term()

  @doc "Handles an invocation, without `c:init/1`'s state or `AWS.Lambda.Runtime.Request`."
  @callback handler(event :: term(), Context.t()) :: result()

  @optional_callbacks init: 1, handle: 3, terminate: 2, handler: 2

  ## Module attributes

  @default_function :handler

  ## Public functions

  @doc """
  Resolves the configured handler into a `{module, function, arity}` tuple,
  raising if it cannot be loaded. Called once during initialisation so that a
  bad handler surfaces as an init error rather than failing every invocation.
  """
  def resolve!() do
    spec =
      System.get_env("RELEASE_LAMBDA_HANDLER") ||
        Application.get_env(:aws_lambda_runtime, :handler) ||
        System.get_env("_HANDLER") ||
        raise ArgumentError,
              "no handler configured: set the function's Handler property, " <>
                "config :aws_lambda_runtime, :handler or the release's handler: option"

    {module, function} = parse!(spec)

    Code.ensure_loaded!(module)

    case function(module, function) do
      {function, arity} ->
        {module, function, arity}

      nil ->
        raise ArgumentError,
              "#{inspect(module)}.#{function}/2 is not exported — the handler must " <>
                "define handle/3, or accept the event and the invocation context"
    end
  end

  @doc """
  The function of a loaded `module` to call for `function`, as given by
  `parse!/1`, with its arity: `handle/3` for a module given alone that
  defines it, else `function/3`, else `function/2`. `nil` when it has none.
  """
  @spec function(module(), atom()) :: {atom(), 2 | 3} | nil
  def function(module, function) do
    cond do
      function == @default_function and function_exported?(module, :handle, 3) -> {:handle, 3}
      function_exported?(module, function, 3) -> {function, 3}
      function_exported?(module, function, 2) -> {function, 2}
      true -> nil
    end
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
