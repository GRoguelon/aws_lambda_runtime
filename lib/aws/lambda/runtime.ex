defmodule AWS.Lambda.Runtime do
  @moduledoc """
  The custom runtime loop.

  Started as a permanent `Task` by the application supervisor. The lifecycle is:

    1. start the `:httpc` profile and resolve the handler (initialisation — any
       failure here is reported to `/runtime/init/error` and halts the VM);
    2. long-poll `GET /runtime/invocation/next`, which is where the sandbox is
       frozen between invocations;
    3. run the handler in a supervised task bounded by the invocation deadline;
    4. post the result to `/response` or the failure to `/error`;
    5. go back to step 2 with the VM still warm.

  Handler failures never crash this process, so a warm sandbox survives a bad
  invocation and the next one avoids a cold start.
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

  ## Public functions

  @doc "Starts the runtime loop as a supervised, permanently-restarted `Task`."
  def start_link(opts \\ []) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  @doc """
  Entry point invoked by `start_link/1` through `Task.start_link/3`.

  Not meant to be called directly — resolves the handler, then loops forever.
  """
  def run(_opts) do
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

    loop(handler)
  end

  ## Private functions

  # Loop

  defp loop(handler) do
    case API.next_invocation() do
      {:ok, headers, raw_event} ->
        context = Context.from_headers(headers)

        Logger.metadata(request_id: context.request_id)

        put_trace_id(context.trace_id)

        process(handler, context, raw_event)

      {:error, reason} ->
        # A failure here is either a transient socket error or the sandbox
        # shutting down. Back off slightly instead of hot-looping.
        Logger.error("could not fetch the next invocation: #{inspect(reason)}")

        Process.sleep(@backoff_ms)
    end

    loop(handler)
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
        apply(module, function, [event, context])
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {:returned, result}

      {:exit, {exception, stacktrace}} when is_exception(exception) ->
        {:raised, exception, stacktrace}

      {:exit, reason} ->
        {:exited, reason}

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

  # Replying

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

  defp reply({:raised, exception, stacktrace}, context) do
    Logger.error(Exception.format(:error, exception, stacktrace))
    report(context, inspect(exception.__struct__), Exception.message(exception), stacktrace)
  end

  defp reply({:exited, reason}, context) do
    Logger.error("handler exited: #{inspect(reason)}")
    report(context, "Handler.Exit", describe(reason), [])
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
        log_failure("response", API.invocation_response(context.request_id, body))

      {:error, message} ->
        report(context, "Runtime.UnserializableResult", message, [])
    end
  end

  defp report(context, type, message, stacktrace) do
    payload = %{
      "errorType" => type,
      "errorMessage" => message,
      "stackTrace" => Enum.map(stacktrace, &Exception.format_stacktrace_entry/1)
    }

    log_failure("error", API.invocation_error(context.request_id, payload, type))
  end

  defp log_failure(_kind, :ok) do
    :ok
  end

  defp log_failure(kind, {:error, reason}) do
    Logger.error("could not post the invocation #{kind}: #{inspect(reason)}")
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

    API.init_error(
      %{
        "errorType" => type,
        "errorMessage" => message,
        "stackTrace" => Enum.map(stacktrace, &Exception.format_stacktrace_entry/1)
      },
      type
    )

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
  # every invocation.
  defp put_trace_id(nil) do
    :ok
  end

  defp put_trace_id(trace_id) do
    System.put_env("_X_AMZN_TRACE_ID", trace_id)
  end
end
