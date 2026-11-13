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

  ## Module attributes

  # Left over so we can report a timeout ourselves before Lambda kills us.
  @deadline_grace_ms 500
  @backoff_ms 200
  @max_next_attempts 5
  @default_stream_content_type "application/octet-stream"
  @stream_send_timeout 30_000
  @boot_poll_ms 1

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

    handler =
      try do
        :ok = API.setup()
        Handler.resolve!()
      catch
        kind, reason ->
          fail_init(kind, reason, __STACKTRACE__)
      end

    {module, function} = handler

    Logger.info("runtime ready, handler #{inspect(module)}.#{function}/2")

    loop(handler, halt, 0)
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

  # Loop

  defp loop(handler, halt, failures) do
    case API.next_invocation() do
      {:ok, headers, raw_event} ->
        context = Context.from_headers(headers)

        Logger.metadata(request_id: context.request_id)

        put_trace_id(context.trace_id)

        handler
        |> process(context, raw_event)
        |> posted(halt)

        loop(handler, halt, 0)

      {:error, {:unexpected_status, status, body}} ->
        # The Runtime API answered: retrying won't change its mind.
        fatal(halt, "the Runtime API answered the next invocation with #{status}: #{body}")

      {:error, reason} when failures + 1 < @max_next_attempts ->
        # Possibly a transient socket error: back off instead of hot-looping.
        Logger.error("could not fetch the next invocation: #{inspect(reason)}")

        Process.sleep(@backoff_ms)

        loop(handler, halt, failures + 1)

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

  defp process({module, function}, context, raw_event) do
    case decode_event(raw_event) do
      {:ok, event} ->
        context
        |> invoke(module, function, event)
        |> reply(context)

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

  defp invoke(context, module, function, event) do
    timeout = invocation_timeout(context)

    task =
      Task.Supervisor.async_nolink(AWS.Lambda.Runtime.TaskSupervisor, fn ->
        Logger.metadata(request_id: context.request_id)

        # A stream is sent from this task, so the deadline below also bounds
        # the handler's enumerable. Failures are returned rather than let
        # crash the task, which would log a crash report on top of ours.
        try do
          case apply(module, function, [event, context]) do
            {:stream, chunks} -> {:streamed, stream(context, chunks, [])}
            {:stream, chunks, opts} -> {:streamed, stream(context, chunks, opts)}
            result -> {:returned, result}
          end
        catch
          kind, reason -> {:failed, kind, reason, __STACKTRACE__}
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

  defp reply({:streamed, posted}, _context) do
    posted
  end

  defp reply({:returned, {:ok, payload}}, context) do
    respond(context, payload)
  end

  defp reply({:returned, {:error, reason}}, context) do
    Logger.error("handler returned an error: #{inspect(reason)}")
    report(context, "Handler.Error", describe(reason), [])
  end

  defp reply({:returned, payload}, context) do
    respond(context, payload)
  end

  defp reply({:failed, kind, reason, stacktrace}, context) do
    Logger.error(Exception.format(kind, reason, stacktrace))

    {type, message} = failure(kind, reason, stacktrace)
    report(context, type, message, stacktrace)
  end

  defp reply({:timed_out, timeout}, context) do
    Logger.error("handler did not return within #{timeout}ms")

    report(
      context,
      "Handler.Timeout",
      "the handler did not return before the invocation deadline (#{timeout}ms)",
      []
    )
  end

  defp respond(context, payload) do
    case encode(payload) do
      {:ok, body} ->
        {"response", API.invocation_response(context.request_id, body)}

      {:error, message} ->
        report(context, "Runtime.UnserializableResult", message, [])
    end
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

  defp fail_init(kind, reason, stacktrace) do
    exception = Exception.normalize(kind, reason, stacktrace)

    {type, message} =
      if is_exception(exception) do
        {inspect(exception.__struct__), Exception.message(exception)}
      else
        {"Runtime.InitError", describe(reason)}
      end

    Logger.error("initialisation failed: #{message}")

    API.init_error(error_payload(type, message, stacktrace), type)

    Logger.flush()
    System.halt(1)
  end

  # Helpers

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
