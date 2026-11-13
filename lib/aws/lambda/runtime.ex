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
  alias AWS.Lambda.Runtime.Events
  alias AWS.Lambda.Runtime.Handler
  alias AWS.Lambda.Runtime.Request
  alias AWS.Lambda.Runtime.Shutdown
  alias AWS.Lambda.Runtime.Telemetry
  alias AWS.Lambda.Runtime.XRay

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

    setup =
      try do
        :ok = API.setup()
        function_url = function_url_mode!()
        {module, _function, _arity} = handler = Handler.resolve!()

        start = System.monotonic_time()
        state = init_handler(module)

        Telemetry.execute(
          [:aws_lambda_runtime, :init, :stop],
          %{duration: System.monotonic_time() - start},
          %{handler: handler}
        )

        %{
          handler: handler,
          state: state,
          function_url: function_url,
          concurrency: max_concurrency(),
          # Shared by the pollers: only the environment's first invocation is
          # a cold start.
          cold_start: :atomics.new(1, [])
        }
      catch
        kind, reason ->
          fail_init(kind, reason, __STACKTRACE__, halt)
      end

    {module, function, arity} = setup.handler

    register_terminate(module, setup.state)
    register_for_shutdown()

    Logger.info(
      "runtime ready, handler #{inspect(module)}.#{function}/#{arity}, " <>
        "function URL mode #{setup.function_url}, #{setup.concurrency} concurrent invocation(s)"
    )

    # On Lambda Managed Instances, an execution environment takes several
    # invocations at once, each poller one at a time. Linked: if one stops,
    # they all restart with the runtime.
    for _poller <- 2..setup.concurrency//1 do
      spawn_link(fn -> loop(setup, halt, 0) end)
    end

    loop(setup, halt, 0)
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

  # Lambda Managed Instances tell how many invocations an execution
  # environment takes at once; standard Lambda, one, doesn't set it.
  defp max_concurrency do
    case Integer.parse(System.get_env("AWS_LAMBDA_MAX_CONCURRENCY", "1")) do
      {concurrency, ""} when concurrency >= 1 ->
        concurrency

      _invalid ->
        Logger.warning(
          "AWS_LAMBDA_MAX_CONCURRENCY must be a positive integer, got: " <>
            "#{inspect(System.get_env("AWS_LAMBDA_MAX_CONCURRENCY"))}, taking one invocation at a time"
        )

        1
    end
  end

  # How the function's URL, if any, invokes it: Lambda doesn't say, and each
  # mode only reads one kind of response.
  defp function_url_mode! do
    case System.get_env("FUNCTION_URL_INVOKE_MODE", "") |> String.trim() |> String.upcase() do
      "" ->
        configured_function_url_mode!()

      "RESPONSE_STREAM" ->
        :response_stream

      "BUFFERED" ->
        :buffered

      other ->
        raise ArgumentError,
              "FUNCTION_URL_INVOKE_MODE must be RESPONSE_STREAM or BUFFERED, got: #{inspect(other)}"
    end
  end

  defp configured_function_url_mode! do
    case Application.get_env(:aws_lambda_runtime, :function_url, :buffered) do
      mode when mode in [:buffered, :response_stream] ->
        mode

      other ->
        raise ArgumentError,
              "config :aws_lambda_runtime, :function_url must be :buffered or :response_stream, " <>
                "got: #{inspect(other)}"
    end
  end

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

  defp loop(setup, halt, failures) do
    case API.next_invocation() do
      {:ok, headers, raw_event} ->
        context = Context.from_headers(headers)

        Logger.metadata(request_id: context.request_id)

        if setup.concurrency == 1, do: put_trace_id(context.trace_id)

        setup
        |> process(context, raw_event)
        |> posted(halt)

        loop(setup, halt, 0)

      {:error, {:unexpected_status, status, body}} ->
        # The Runtime API answered: retrying won't change its mind.
        fatal(halt, "the Runtime API answered the next invocation with #{status}: #{body}")

      {:error, reason} when failures + 1 < @max_next_attempts ->
        # Possibly a transient socket error: back off instead of hot-looping.
        Logger.error("could not fetch the next invocation: #{inspect(reason)}")

        Process.sleep(@backoff_ms)

        loop(setup, halt, failures + 1)

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

  defp process(%{handler: {module, function, arity}} = setup, context, raw_event) do
    case decode_event(raw_event) do
      {:ok, event} ->
        case input(event, arity) do
          {:ok, input} ->
            args = if arity == 3, do: [input, context, setup.state], else: [input, context]
            http = http_reply(input, setup.function_url)

            metadata = %{
              request_id: context.request_id,
              context: context,
              handler: setup.handler,
              event_type: event_type(input),
              cold_start: :atomics.compare_exchange(setup.cold_start, 1, 0, 1) == :ok
            }

            start = invocation_started(metadata)
            result = invoke(context, module, function, args, input, http)
            invocation_done(result, start, metadata)

            reply(result, context, input, http)

          {:error, message, request} ->
            Logger.info("bad request, not calling the handler: #{message}")
            http = http_reply(request, setup.function_url)
            respond(context, request, %{"message" => message}, [status: 400], http)

          {:malformed, message} ->
            Logger.error("malformed event, not calling the handler: #{message}")
            report(context, "Runtime.MalformedEvent", message, [])
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

  # Telemetry

  defp invocation_started(metadata) do
    start = System.monotonic_time()

    Telemetry.execute(
      [:aws_lambda_runtime, :invocation, :start],
      %{system_time: System.system_time(), monotonic_time: start},
      metadata
    )

    start
  end

  defp invocation_done(result, start, metadata) do
    stop = System.monotonic_time()
    measurements = %{duration: stop - start, monotonic_time: stop}

    case result do
      {:failed, kind, reason, stacktrace} ->
        Telemetry.execute(
          [:aws_lambda_runtime, :invocation, :exception],
          measurements,
          Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
        )

      result ->
        Telemetry.execute(
          [:aws_lambda_runtime, :invocation, :stop],
          measurements,
          Map.put(metadata, :result, result_type(result))
        )
    end
  end

  defp result_type({:streamed, _posted}), do: :stream
  defp result_type({:returned, {:error, _reason}}), do: :error
  defp result_type({:returned, {:retry, _failed}}), do: :retry
  defp result_type({:returned, _result}), do: :ok
  defp result_type({:unmatched, _mfa}), do: :unmatched
  defp result_type({:timed_out, _timeout}), do: :timeout

  defp event_type(%Request{}), do: :request
  defp event_type(%Events.SQS{}), do: :sqs
  defp event_type(%Events.SNS{}), do: :sns
  defp event_type(%Events.S3{}), do: :s3
  defp event_type(%Events.EventBridge{}), do: :event_bridge
  defp event_type(%Events.Kinesis{}), do: :kinesis
  defp event_type(%Events.DynamoDB{}), do: :dynamodb
  defp event_type(_event), do: :event

  # handle/3 gets an HTTP request or a service's event decoded, handler/2 the
  # event as it is.
  defp input(event, 3) do
    case Request.from_event(event) do
      {:ok, request} -> {:ok, request}
      {:error, message} -> {:error, message, Request.unreadable(event)}
      :error -> service_event(event)
    end
  end

  defp input(event, 2) do
    {:ok, event}
  end

  defp service_event(event) do
    case Events.decode(event) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, message} -> {:malformed, message}
      :error -> {:ok, event}
    end
  end

  defp invoke(context, module, function, args, input, http) do
    timeout = invocation_timeout(context)

    task =
      Task.Supervisor.async_nolink(AWS.Lambda.Runtime.TaskSupervisor, fn ->
        Logger.metadata(request_id: context.request_id)
        XRay.put_trace_header(context.trace_id)

        # A stream is sent from this task, so the deadline below also bounds
        # the handler's enumerable. Failures are returned rather than let
        # crash the task, which would log a crash report on top of ours.
        try do
          case apply(module, function, args) do
            {:stream, chunks} ->
              streamed_or_collected(context, chunks, [], input, http)

            {:stream, chunks, opts} ->
              streamed_or_collected(context, chunks, opts, input, http)

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

  # A request answered with the envelope gets the stream's chunks collected
  # into its body, here in the task, so the deadline still bounds them.
  defp streamed_or_collected(_context, chunks, opts, _input, :envelope) do
    opts = Keyword.validate!(opts, [:content_type, :http, :send_timeout | @http_options])
    {http, opts} = Keyword.split(opts, @http_options)
    content_type = Keyword.get(opts, :content_type, @default_stream_content_type)
    body = chunks |> Enum.to_list() |> IO.iodata_to_binary()

    {:returned, {:ok, body, [content_type: content_type] ++ Keyword.get(opts, :http, http)}}
  end

  defp streamed_or_collected(context, chunks, opts, input, _http) do
    {:streamed, stream(context, chunks, stream_opts(opts, input))}
  end

  # How a request's response must be sent: Lambda only reads a stream with
  # a prelude from a Function URL in RESPONSE_STREAM mode, and only an
  # envelope otherwise. nil for any other event.
  defp http_reply(%Request{source: :function_url}, :response_stream), do: :stream
  defp http_reply(%Request{}, _function_url), do: :envelope
  defp http_reply(_event, _function_url), do: nil

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
      "headers" =>
        http[:headers] |> downcase_headers() |> Map.put_new("content-type", content_type),
      "cookies" => http[:cookies]
    }
  end

  # So a header given as "Content-Type" isn't sent twice, and the stream's
  # headers read like the envelope's.
  defp downcase_headers(headers) do
    Map.new(headers, fn {name, value} -> {name |> to_string() |> String.downcase(), value} end)
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

  defp reply({:streamed, posted}, _context, _input, _http) do
    posted
  end

  defp reply({:returned, {:ok, body}}, context, input, http) do
    respond(context, input, body, [], http)
  end

  defp reply({:returned, {:ok, body, opts}}, context, input, http) when is_list(opts) do
    respond(context, input, body, opts, http)
  end

  # Only the failed records of a batch are retried.
  defp reply({:returned, {:retry, failed}}, context, input, http) do
    case Events.batch_item_failures(failed) do
      {:ok, response} ->
        Logger.info("retrying #{length(response["batchItemFailures"])} record(s) of the batch")
        respond(context, input, response, [], http)

      {:error, message} ->
        report(context, "Runtime.InvalidResponse", message, [])
    end
  end

  defp reply({:returned, {:error, reason}}, context, _input, _http) do
    Logger.error("handler returned an error: #{inspect(reason)}")
    report(context, "Handler.Error", describe(reason), [])
  end

  defp reply({:returned, body}, context, input, http) do
    respond(context, input, body, [], http)
  end

  # A route nobody handles, as a router would answer it.
  defp reply({:unmatched, {module, function, arity}}, context, %Request{} = request, http) do
    Logger.warning(
      "no clause of #{Exception.format_mfa(module, function, arity)} matches " <>
        "#{request.method} #{request.path}, answering 404"
    )

    respond(context, request, %{"message" => "Not Found"}, [status: 404], http)
  end

  defp reply({:unmatched, {module, function, arity}}, context, event, _http) do
    mfa = Exception.format_mfa(module, function, arity)

    Logger.error(
      "no clause of #{mfa} matches the event: " <>
        inspect(event, limit: 10, printable_limit: 200)
    )

    report(context, "Runtime.UnhandledEvent", "no clause of #{mfa} matches the event", [])
  end

  defp reply({:failed, kind, reason, stacktrace}, context, _input, _http) do
    Logger.error(Exception.format(kind, reason, stacktrace))

    {type, message} = failure(kind, reason, stacktrace)
    report(context, type, message, stacktrace)
  end

  defp reply({:timed_out, timeout}, context, _input, _http) do
    Logger.error("handler did not return within #{timeout}ms")

    report(
      context,
      "Handler.Timeout",
      "the handler did not return before the invocation deadline (#{timeout}ms)",
      []
    )
  end

  # A Function URL in RESPONSE_STREAM mode only reads a stream: the body is
  # its single chunk, after the prelude.
  defp respond(context, _request, body, opts, :stream) do
    with {:ok, opts} <- validate_response_options(opts),
         {:ok, content, content_type} <- http_body(body, opts[:content_type]) do
      stream(context, [content],
        content_type: content_type,
        http: Keyword.take(opts, @http_options)
      )
    else
      {:error, :options, message} ->
        report(context, "Runtime.InvalidResponse", message, [])

      {:error, message} ->
        report(context, "Runtime.UnserializableResult", message, [])
    end
  end

  defp respond(context, input, body, opts, _http) do
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
        |> downcase_headers()
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
