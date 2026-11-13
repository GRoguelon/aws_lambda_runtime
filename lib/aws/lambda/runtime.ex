defmodule AWS.Lambda.Runtime do
  @moduledoc """
  The custom runtime loop.

  Started as a permanent `Task` by the application supervisor. The lifecycle is:

    1. wait until the release has started every application. The function's
       own application depends on this one, so it starts after it; polling the
       Runtime API earlier would end Lambda's init phase and run the first
       invocation against a half-started system;
    2. read the Runtime API endpoint and resolve the handler (initialisation — any
       failure here is reported to `/runtime/init/error` and halts the VM);
    3. long-poll `GET /runtime/invocation/next`, which is where the sandbox is
       frozen between invocations;
    4. run the handler in a supervised task bounded by the invocation deadline;
    5. post the result to `/response` or the failure to `/error`;
    6. go back to step 3 with the VM still warm.

  Handler failures never crash this process, so a warm sandbox survives a bad
  invocation and the next one avoids a cold start.

  Runtime API failures are different: as its contract requires, the VM exits
  when `/next` answers with an error status, when posting a result gets a
  `500` (container error), or when `/next` stays unreachable after a few
  attempts, so that Lambda replaces the sandbox.
  """

  use Task, restart: :permanent

  require Logger

  alias AWS.Lambda.Runtime.API
  alias AWS.Lambda.Runtime.Context
  alias AWS.Lambda.Runtime.Handler
  alias AWS.Lambda.Runtime.Request
  alias AWS.Lambda.Runtime.Shutdown

  ## Module attributes

  # Left over so we can report a timeout ourselves before Lambda kills us.
  @deadline_grace_ms 500
  @backoff_ms 200
  @max_next_attempts 5
  @default_stream_content_type "application/octet-stream"
  @stream_send_timeout 30_000
  @boot_poll_ms 1
  @extension_name "aws_lambda_runtime"
  @init_info_keys [:function_name, :function_version, :memory_limit_mb, :log_group, :log_stream]
  @response_options [:status, :headers, :cookies, :content_type]
  @http_options [:status, :headers, :cookies]

  ## Public functions

  @doc """
  Starts the runtime loop as a supervised, permanently-restarted `Task`.

  ## Options

    * `:halt` - function called with the exit status when a Runtime API
      failure requires the VM to exit. Defaults to `System.halt/1`.
  """
  def start_link(opts \\ []) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  @doc """
  Entry point invoked by `start_link/1` through `Task.start_link/3`.

  Not meant to be called directly — waits for the boot to complete, resolves
  the handler, then loops forever.
  """
  def run(opts) do
    halt = Keyword.get(opts, :halt, &System.halt/1)

    wait_for_boot()

    {handler, state} =
      try do
        :ok = API.setup()
        {module, _function, _arity} = handler = Handler.resolve!()
        {handler, init_handler(module)}
      catch
        kind, reason ->
          fail_init(kind, reason, __STACKTRACE__, halt)
      end

    {module, function, arity} = handler

    register_terminate(module, state)
    register_for_shutdown()

    Logger.info("runtime ready, handler #{inspect(module)}.#{function}/#{arity}")

    loop(handler, state, halt, 0)
  end

  ## Private functions

  # Boot

  # The boot script ends with `{progress, started}`, which sets the provided
  # status once every application, the function's own included, has started.
  # The internal status only follows after the `-s`/`-eval` commands, and those
  # include Elixir's CLI, which never returns under `mix test` or `iex -S mix`.
  defp wait_for_boot do
    case :init.get_status() do
      {:stopping, _provided} ->
        # The VM is shutting down, possibly because an application failed to
        # start: there is nothing to serve.
        Process.sleep(:infinity)

      {_internal, :started} ->
        :ok

      {_internal, _provided} ->
        Process.sleep(@boot_poll_ms)
        wait_for_boot()
    end
  end

  # Handler

  # Called once wait_for_boot/0 has seen every application started, so init/1
  # can use what the function's application started, such as an Ecto repo.
  defp init_handler(module) do
    if function_exported?(module, :init, 1) do
      case module.init(init_info()) do
        {:ok, state} -> state
        {:error, reason} -> throw({:init_error, reason})
        other -> throw({:init_error, {:bad_return, other}})
      end
    end
  end

  defp init_info do
    %{}
    |> Context.from_headers()
    |> Map.from_struct()
    |> Map.take(@init_info_keys)
    |> Map.put(:region, System.get_env("AWS_REGION"))
  end

  # terminate/2 is a shutdown function like any other, so implementing it is
  # enough for Lambda to send the SIGTERM.
  defp register_terminate(module, state) do
    if function_exported?(module, :terminate, 2) do
      Shutdown.register(fn -> module.terminate(:shutdown, state) end)
    end
  end

  # Lambda only sends a SIGTERM before shutting the execution environment
  # down when an extension is registered, which it must be before the first
  # /next. Not being warned isn't worth failing the init phase for.
  defp register_for_shutdown do
    if Shutdown.registered?() do
      case API.register_extension(@extension_name, []) do
        {:ok, id} ->
          # Lambda holds every invocation back until each registered
          # extension waits for its next event.
          {:ok, _pid} =
            Task.Supervisor.start_child(AWS.Lambda.Runtime.TaskSupervisor, fn ->
              poll_extension_events(id)
            end)

          :ok

        {:error, reason} ->
          Logger.warning(
            "could not register for SIGTERM, shutdown functions won't run: #{inspect(reason)}"
          )
      end
    end
  end

  # Registered for no event, the extension gets none: the request stays
  # pending, which is all Lambda needs.
  defp poll_extension_events(id) do
    case API.next_extension_event(id) do
      {:ok, _headers, _body} ->
        poll_extension_events(id)

      {:error, reason} ->
        Logger.warning("the shutdown extension stopped waiting for events: #{inspect(reason)}")
    end
  end

  # Loop

  defp loop(handler, state, halt, failures) do
    case API.next_invocation() do
      {:ok, headers, raw_event} ->
        context = Context.from_headers(headers)

        Logger.metadata(request_id: context.request_id)

        put_trace_id(context.trace_id)

        handler
        |> process(context, raw_event, state)
        |> posted(halt)

        loop(handler, state, halt, 0)

      {:error, {:unexpected_status, status, body}} ->
        # The Runtime API answered: retrying won't change its mind.
        fatal(halt, "the Runtime API answered the next invocation with #{status}: #{body}")

      {:error, reason} when failures + 1 < @max_next_attempts ->
        # Possibly a transient socket error: back off instead of hot-looping.
        Logger.error("could not fetch the next invocation: #{inspect(reason)}")

        Process.sleep(@backoff_ms)

        loop(handler, state, halt, failures + 1)

      {:error, reason} ->
        fatal(halt, "could not fetch the next invocation: #{inspect(reason)}")
    end
  end

  defp posted({_kind, :ok}, _halt) do
    :ok
  end

  defp posted({kind, {:error, {:unexpected_status, 500, body}}}, halt) do
    fatal(halt, "the Runtime API answered the invocation #{kind} with 500: #{body}")
  end

  defp posted({kind, {:error, reason}}, _halt) do
    Logger.error("could not post the invocation #{kind}: #{inspect(reason)}")
  end

  defp fatal(halt, message) do
    Logger.error(message <> ", exiting")
    Logger.flush()
    halt.(1)
  end

  defp process({module, function, arity}, context, raw_event, state) do
    case decode_event(raw_event) do
      {:ok, event} ->
        case input(event, arity) do
          {:ok, input} ->
            args = if arity == 3, do: [input, context, state], else: [input, context]

            context
            |> invoke(module, function, args, input)
            |> reply(context, input)

          {:error, message, request} ->
            Logger.info("bad request, not calling the handler: #{message}")
            respond(context, request, %{"message" => message}, status: 400)
        end

      {:error, reason} ->
        report(
          context,
          "Runtime.MalformedEvent",
          "the invocation payload is not valid JSON: #{inspect(reason)}",
          []
        )
    end
  end

  # Dispatch

  # handle/3 gets an HTTP request decoded, handler/2 the event as it is.
  defp input(event, 3) do
    case Request.from_event(event) do
      {:ok, request} -> {:ok, request}
      :error -> {:ok, event}
      {:error, message} -> {:error, message, %Request{event: event, format: format(event)}}
    end
  end

  defp input(event, 2) do
    {:ok, event}
  end

  defp format(%{"version" => "2.0"}), do: :v2
  defp format(_event), do: :v1

  defp invoke(context, module, function, args, input) do
    timeout = invocation_timeout(context)

    task =
      Task.Supervisor.async_nolink(AWS.Lambda.Runtime.TaskSupervisor, fn ->
        Logger.metadata(request_id: context.request_id)

        # A stream is sent from this task, so the deadline below also bounds
        # the handler's enumerable. Failures are returned rather than let
        # crash the task, which would log a crash report on top of ours.
        try do
          case apply(module, function, args) do
            {:stream, chunks} ->
              {:streamed, stream(context, chunks, stream_opts([], input))}

            {:stream, chunks, opts} ->
              {:streamed, stream(context, chunks, stream_opts(opts, input))}

            result ->
              {:returned, result}
          end
        catch
          kind, reason ->
            # No clause of the handler itself matches: not a bug in its code.
            if kind == :error and reason == :function_clause and
                 unmatched?(__STACKTRACE__, module, function, args) do
              {:unmatched, {module, function, length(args)}}
            else
              {:failed, kind, reason, __STACKTRACE__}
            end
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      # The task was killed from outside, e.g. by a process linked to it.
      {:exit, {exception, stacktrace}} when is_exception(exception) ->
        {:failed, :error, exception, stacktrace}

      {:exit, reason} ->
        {:failed, :exit, reason, []}

      nil ->
        {:timed_out, timeout}
    end
  end

  defp invocation_timeout(context) do
    case Context.remaining_time_ms(context) do
      :infinity ->
        :infinity

      remaining ->
        max(remaining - @deadline_grace_ms, 50)
    end
  end

  # Streaming

  defp stream(context, chunks, opts) do
    opts =
      Keyword.validate!(opts,
        content_type: @default_stream_content_type,
        http: nil,
        send_timeout: @stream_send_timeout
      )

    prelude = opts[:http] && prelude(opts[:http], opts[:content_type])

    {"response",
     API.invocation_response_stream(context.request_id, chunks,
       content_type: opts[:content_type],
       prelude: prelude,
       send_timeout: opts[:send_timeout],
       on_error: &stream_error/3
     )}
  end

  # For a request, the HTTP options make the prelude; :http, which
  # handler/2 sets them with, still wins.
  defp stream_opts(opts, %Request{}) do
    {http, opts} = Keyword.split(opts, @http_options)
    Keyword.put_new(opts, :http, http)
  end

  defp stream_opts(opts, _event) do
    Keyword.drop(opts, @http_options)
  end

  defp prelude(http, content_type) do
    http = Keyword.validate!(http, status: 200, headers: %{}, cookies: [])

    %{
      "statusCode" => http[:status],
      "headers" => Map.put_new(http[:headers], "content-type", content_type),
      "cookies" => http[:cookies]
    }
  end

  # Once the first chunk is sent the response is committed: the error can
  # only travel in the stream's trailers.
  defp stream_error(kind, reason, stacktrace) do
    Logger.error("handler failed while streaming: " <> Exception.format(kind, reason, stacktrace))

    {type, message} = failure(kind, reason, stacktrace)

    {type, error_payload(type, message, stacktrace)}
  end

  # The error type and message a raise, throw or exit is reported with.
  defp failure(kind, reason, stacktrace) do
    case Exception.normalize(kind, reason, stacktrace) do
      exception when is_exception(exception) ->
        {inspect(exception.__struct__), Exception.message(exception)}

      _reason when kind == :throw ->
        {"Handler.Throw", describe(reason)}

      _reason ->
        {"Handler.Exit", describe(reason)}
    end
  end

  # Replying

  defp reply({:streamed, posted}, _context, _input) do
    posted
  end

  defp reply({:returned, {:ok, body}}, context, input) do
    respond(context, input, body, [])
  end

  defp reply({:returned, {:ok, body, opts}}, context, input) when is_list(opts) do
    respond(context, input, body, opts)
  end

  defp reply({:returned, {:error, reason}}, context, _input) do
    Logger.error("handler returned an error: #{inspect(reason)}")
    report(context, "Handler.Error", describe(reason), [])
  end

  defp reply({:returned, body}, context, input) do
    respond(context, input, body, [])
  end

  # A route nobody handles, as a router would answer it.
  defp reply({:unmatched, {module, function, arity}}, context, %Request{} = request) do
    Logger.warning(
      "no clause of #{Exception.format_mfa(module, function, arity)} matches " <>
        "#{request.method} #{request.path}, answering 404"
    )

    respond(context, request, %{"message" => "Not Found"}, status: 404)
  end

  defp reply({:unmatched, {module, function, arity}}, context, event) do
    mfa = Exception.format_mfa(module, function, arity)

    Logger.error(
      "no clause of #{mfa} matches the event: " <>
        inspect(event, limit: 10, printable_limit: 200)
    )

    report(context, "Runtime.UnhandledEvent", "no clause of #{mfa} matches the event", [])
  end

  defp reply({:failed, kind, reason, stacktrace}, context, _input) do
    Logger.error(Exception.format(kind, reason, stacktrace))

    {type, message} = failure(kind, reason, stacktrace)
    report(context, type, message, stacktrace)
  end

  defp reply({:timed_out, timeout}, context, _input) do
    Logger.error("handler did not return within #{timeout}ms")

    report(
      context,
      "Handler.Timeout",
      "the handler did not return before the invocation deadline (#{timeout}ms)",
      []
    )
  end

  defp respond(context, input, body, opts) do
    with {:ok, opts} <- validate_response_options(opts),
         {:ok, payload} <- encode_response(input, body, opts) do
      {"response", API.invocation_response(context.request_id, payload)}
    else
      {:error, :options, message} ->
        report(context, "Runtime.InvalidResponse", message, [])

      {:error, message} ->
        report(context, "Runtime.UnserializableResult", message, [])
    end
  end

  defp validate_response_options(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.validate(opts, @response_options) do
        {:ok, opts} -> {:ok, opts}
        {:error, unknown} -> {:error, :options, "unknown response options: #{inspect(unknown)}"}
      end
    else
      {:error, :options, "the response options must be a keyword list, got: #{inspect(opts)}"}
    end
  end

  # As a Function URL or API Gateway expects it, in the request's format.
  defp encode_response(%Request{format: format}, body, opts) do
    with {:ok, content, content_type} <- http_body(body, opts[:content_type]) do
      {encoded?, content} =
        if String.valid?(content), do: {false, content}, else: {true, Base.encode64(content)}

      headers =
        opts
        |> Keyword.get(:headers, %{})
        |> Map.new(fn {name, value} -> {name |> to_string() |> String.downcase(), value} end)
        |> Map.put_new("content-type", content_type)

      %{
        "statusCode" => Keyword.get(opts, :status, 200),
        "headers" => headers,
        "body" => content,
        "isBase64Encoded" => encoded?
      }
      |> put_cookies(format, Keyword.get(opts, :cookies, []))
      |> encode()
    end
  end

  defp encode_response(_event, body, opts) do
    if is_binary(body) and is_binary(opts[:content_type]) do
      {:ok, body}
    else
      encode(body)
    end
  end

  defp http_body(body, content_type) when is_binary(body) and is_binary(content_type) do
    {:ok, body, content_type}
  end

  defp http_body(body, content_type) do
    with {:ok, json} <- encode(body) do
      {:ok, IO.iodata_to_binary(json), content_type || "application/json"}
    end
  end

  defp put_cookies(response, _format, []), do: response
  defp put_cookies(response, :v2, cookies), do: Map.put(response, "cookies", cookies)

  defp put_cookies(response, :v1, cookies) do
    Map.put(response, "multiValueHeaders", %{"set-cookie" => cookies})
  end

  defp report(context, type, message, stacktrace) do
    payload = error_payload(type, message, stacktrace)

    {"error", API.invocation_error(context.request_id, payload, type)}
  end

  defp error_payload(type, message, stacktrace) do
    %{
      "errorType" => type,
      "errorMessage" => message,
      "stackTrace" => Enum.map(stacktrace, &Exception.format_stacktrace_entry/1)
    }
  end

  # Initialisation failure

  defp fail_init(kind, reason, stacktrace, halt) do
    exception = Exception.normalize(kind, reason, stacktrace)

    {type, message} =
      cond do
        match?({:throw, {:init_error, _reason}}, {kind, reason}) ->
          {:init_error, reason} = reason
          {"Runtime.InitError", "init/1 failed: #{describe(reason)}"}

        is_exception(exception) ->
          {inspect(exception.__struct__), Exception.message(exception)}

        true ->
          {"Runtime.InitError", describe(reason)}
      end

    Logger.error("initialisation failed: #{message}")

    API.init_error(error_payload(type, message, stacktrace), type)

    Logger.flush()
    halt.(1)

    # Only reached when halt/1 is stubbed, in tests.
    exit(:normal)
  end

  # Helpers

  # The function clause error comes from the call to the handler itself, the
  # top of the stack, rather than from a call made from it.
  defp unmatched?([{module, function, args_or_arity, _location} | _rest], module, function, args) do
    args_or_arity == args or args_or_arity == length(args)
  end

  defp unmatched?(_stacktrace, _module, _function, _args) do
    false
  end

  defp decode_event("") do
    {:ok, nil}
  end

  defp decode_event(raw) do
    JSON.decode(raw)
  end

  defp encode(payload) do
    {:ok, JSON.encode_to_iodata!(payload)}
  rescue
    exception ->
      {:error,
       "the handler returned a value that cannot be encoded as JSON: " <>
         Exception.message(exception)}
  end

  defp describe(reason) when is_binary(reason) do
    reason
  end

  defp describe(reason) do
    inspect(reason)
  end

  # X-Ray SDKs read the trace header off the environment, and it changes on
  # every invocation: one without a header must not inherit the previous one's.
  defp put_trace_id(nil) do
    System.delete_env("_X_AMZN_TRACE_ID")
  end

  defp put_trace_id(trace_id) do
    System.put_env("_X_AMZN_TRACE_ID", trace_id)
  end
end
