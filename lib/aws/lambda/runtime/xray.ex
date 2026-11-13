defmodule AWS.Lambda.Runtime.XRay do
  @moduledoc """
  Records [X-Ray](https://docs.aws.amazon.com/xray/latest/devguide/aws-xray.html)
  subsegments from a handler, so the work it does shows up in the trace of the
  invocation.

  With the function's tracing mode set to `Active`, Lambda already records
  the invocation in a segment of its own. Each subsegment recorded here is
  attached to it, timed, and sent to the X-Ray daemon running in the sandbox
  (see `AWS.Lambda.Runtime.XRay.Daemon`):

      XRay.subsegment("load_user", fn -> Repo.get(User, id) end,
        annotations: %{user_id: id}
      )

  Nothing is recorded unless the invocation is sampled, which the trace
  header Lambda hands to the runtime says (`Sampled=1`): the function is then
  called as is, and none of the functions below sends anything.

  ## Nesting

  A subsegment started while another is open in the same process is recorded
  as its child. Other processes don't see it, so a subsegment recorded from a
  `Task` is attached to the invocation's segment, unless it is given the
  header of the one to attach to:

      XRay.subsegment("fetch_all", fn ->
        header = XRay.trace_header()

        ids
        |> Task.async_stream(fn id ->
          XRay.subsegment("fetch", fn -> fetch(id) end, trace_header: header)
        end)
        |> Enum.to_list()
      end)

  ## Downstream calls

  A request to another service joins the same trace when it carries the
  current trace header, which `trace_header/0` returns:

      Req.get!(url, headers: [{"x-amzn-trace-id", XRay.trace_header()}])

  ## Errors

  A raise, throw or exit leaving `subsegment/3` marks the subsegment as a
  fault, records the exception and its stack trace, and goes on unchanged.
  For an HTTP call, a `4xx` response status marks it as an error, `429` as
  throttled too, and a `5xx` as a fault.
  """

  alias AWS.Lambda.Runtime.XRay.Daemon

  ## Types

  @typedoc """
  Options to start a subsegment:

    * `:namespace` - `"aws"` for a call to an AWS service, `"remote"` for any
      other downstream call.
    * `:annotations` - a map of values X-Ray indexes for filtering traces:
      strings, numbers, booleans or atoms.
    * `:metadata` - a map of any JSON-encodable values, recorded under the
      `default` namespace.
    * `:http`, `:sql`, `:aws` - the subsegment's fields of the same name, as
      maps (see the X-Ray segment document reference), e.g.
      `http: %{request: %{method: "GET", url: url}}`.
    * `:trace_header` - the trace header to attach the subsegment to, instead
      of the open subsegment or, outside of one, the invocation's.
  """
  @type begin_option ::
          {:namespace, String.t() | atom()}
          | {:annotations, map()}
          | {:metadata, map()}
          | {:http, map()}
          | {:sql, map()}
          | {:aws, map()}
          | {:trace_header, String.t() | nil}

  @typedoc """
  Options to end a subsegment: `:annotations`, `:metadata`, `:http`, `:sql`
  and `:aws` as when starting it, merged into what it has, plus:

    * `:exception` - the `{kind, reason, stacktrace}` of a failure, which marks
      the subsegment as a fault.
  """
  @type end_option ::
          {:annotations, map()}
          | {:metadata, map()}
          | {:http, map()}
          | {:sql, map()}
          | {:aws, map()}
          | {:exception, {:error | :exit | :throw, term(), Exception.stacktrace()}}

  ## Module attributes

  @stack_key {__MODULE__, :stack}

  # Set by the runtime for each invocation.
  @trace_env "_X_AMZN_TRACE_ID"

  @fields [:annotations, :metadata, :http, :sql, :aws]

  ## Public functions

  @doc """
  Calls `fun` in a subsegment named `name`, and returns its result.

  See `t:begin_option/0` for the options.
  """
  @spec subsegment(String.t(), (-> result), [begin_option()]) :: result when result: term()
  def subsegment(name, fun, opts \\ []) when is_function(fun, 0) do
    :ok = begin_subsegment(name, opts)

    try do
      fun.()
    catch
      kind, reason ->
        end_subsegment(exception: {kind, reason, __STACKTRACE__})
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result ->
        end_subsegment()
        result
    end
  end

  @doc """
  Starts a subsegment named `name` in the calling process, to be ended by
  `end_subsegment/1`.

  Prefer `subsegment/3`, which can't leave one open. See `t:begin_option/0`
  for the options.
  """
  @spec begin_subsegment(String.t(), [begin_option()]) :: :ok
  def begin_subsegment(name, opts \\ []) when is_binary(name) do
    opts = Keyword.validate!(opts, [:namespace, :trace_header | @fields])

    context =
      case Keyword.fetch(opts, :trace_header) do
        {:ok, header} -> parse_trace_header(header)
        :error -> current_context()
      end

    frame =
      case context do
        %{root: root, parent: parent_id, sampled: "1"} when is_binary(parent_id) ->
          id = new_id()

          document =
            %{
              "id" => id,
              "name" => name,
              "trace_id" => root,
              "parent_id" => parent_id,
              "type" => "subsegment",
              "start_time" => now()
            }
            |> put_namespace(opts[:namespace])
            |> put_fields(opts)

          %{context: %{context | parent: id}, document: document}

        _untraced ->
          %{context: context, document: nil}
      end

    Process.put(@stack_key, [frame | stack()])

    :ok
  end

  @doc """
  Ends the subsegment last started in the calling process, and sends it.

  Does nothing when none is open. See `t:end_option/0` for the options.
  """
  @spec end_subsegment([end_option()]) :: :ok
  def end_subsegment(opts \\ []) do
    opts = Keyword.validate!(opts, [:exception | @fields])

    case stack() do
      [] ->
        :ok

      [%{document: document} | rest] ->
        put_stack(rest)

        if document do
          document = put_fields(document, opts)

          document
          |> Map.put("end_time", now())
          |> put_status(get_in(document, ["http", "response", "status"]))
          |> put_exception(opts[:exception])
          |> Daemon.send_document()
        end

        :ok
    end
  end

  @doc """
  Adds an annotation to the open subsegment, if any: a value X-Ray indexes
  for filtering traces.
  """
  @spec put_annotation(String.t() | atom(), String.t() | number() | boolean() | atom()) :: :ok
  def put_annotation(key, value) do
    update_document(&put_fields(&1, annotations: %{key => value}))
  end

  @doc """
  Adds metadata to the open subsegment, if any, under the `default`
  namespace. `value` must be JSON-encodable.
  """
  @spec put_metadata(String.t() | atom(), term()) :: :ok
  def put_metadata(key, value) do
    update_document(&put_fields(&1, metadata: %{key => value}))
  end

  @doc """
  The trace header for a call made from here: the invocation's, with the
  open subsegment, if any, as its parent.

  `nil` outside of an invocation. An invocation that isn't sampled still has
  one, so the services it calls don't sample it either.
  """
  @spec trace_header() :: String.t() | nil
  def trace_header do
    case current_context() do
      nil ->
        nil

      context ->
        [{"Root", context.root}, {"Parent", context.parent}, {"Sampled", context.sampled}]
        |> Enum.concat(context.fields)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Enum.map_join(";", fn {key, value} -> key <> "=" <> value end)
    end
  end

  ## Private functions

  # Context

  defp stack do
    Process.get(@stack_key, [])
  end

  defp put_stack([]) do
    Process.delete(@stack_key)
  end

  defp put_stack(stack) do
    Process.put(@stack_key, stack)
  end

  defp current_context do
    case stack() do
      [%{context: context} | _rest] -> context
      [] -> @trace_env |> System.get_env() |> parse_trace_header()
    end
  end

  defp update_document(fun) do
    case stack() do
      [%{document: document} = frame | rest] when document != nil ->
        put_stack([%{frame | document: fun.(document)} | rest])

      _untraced ->
        :ok
    end

    :ok
  end

  # "Root=1-5759e988-bd862e3fe1be46a994272793;Parent=53995c3f42cd8ad8;Sampled=1",
  # possibly with more fields, such as Lineage, which are passed on as is.
  defp parse_trace_header(nil) do
    nil
  end

  defp parse_trace_header(header) when is_binary(header) do
    fields =
      for field <- String.split(header, ";", trim: true),
          [key, value] <- [String.split(field, "=", parts: 2)],
          do: {String.trim(key), String.trim(value)}

    {known, others} =
      Enum.split_with(fields, fn {key, _value} -> key in ~w[Root Parent Sampled] end)

    known = Map.new(known)

    if root = known["Root"] do
      %{root: root, parent: known["Parent"], sampled: known["Sampled"], fields: others}
    end
  end

  # Document

  defp put_namespace(document, nil) do
    document
  end

  defp put_namespace(document, namespace) do
    Map.put(document, "namespace", to_string(namespace))
  end

  defp put_fields(document, opts) do
    Enum.reduce(@fields, document, fn field, document ->
      case opts[field] do
        value when is_nil(value) or value == %{} -> document
        value -> merge(document, field, value)
      end
    end)
  end

  defp merge(document, :annotations, annotations) do
    annotations = Map.new(annotations, fn {key, value} -> {to_string(key), annotation(value)} end)

    Map.update(document, "annotations", annotations, &Map.merge(&1, annotations))
  end

  defp merge(document, :metadata, metadata) do
    metadata = %{"default" => Map.new(metadata, fn {key, value} -> {to_string(key), value} end)}

    Map.update(document, "metadata", metadata, &deep_merge(&1, metadata))
  end

  defp merge(document, field, value) do
    value = stringify_keys(value)

    Map.update(document, Atom.to_string(field), value, &deep_merge(&1, value))
  end

  defp annotation(value) when is_binary(value) or is_number(value) or is_boolean(value) do
    value
  end

  defp annotation(value) when is_atom(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(value) do
    value
  end

  defp deep_merge(left, right)
       when is_map(left) and not is_struct(left) and is_map(right) and not is_struct(right) do
    Map.merge(left, right, fn _key, left, right -> deep_merge(left, right) end)
  end

  defp deep_merge(_left, right) do
    right
  end

  defp put_status(document, 429) do
    Map.merge(document, %{"error" => true, "throttle" => true})
  end

  defp put_status(document, status) when status in 400..499 do
    Map.put(document, "error", true)
  end

  defp put_status(document, status) when status in 500..599 do
    Map.put(document, "fault", true)
  end

  defp put_status(document, _status) do
    document
  end

  defp put_exception(document, nil) do
    document
  end

  defp put_exception(document, {kind, reason, stacktrace}) do
    {type, message} =
      case Exception.normalize(kind, reason, stacktrace) do
        exception when is_exception(exception) ->
          {inspect(exception.__struct__), Exception.message(exception)}

        _reason ->
          {kind |> Atom.to_string() |> String.capitalize(), describe(reason)}
      end

    exception = %{
      "id" => new_id(),
      "type" => type,
      "message" => message,
      "stack" => Enum.map(stacktrace, &stack_frame/1)
    }

    cause =
      case File.cwd() do
        {:ok, cwd} -> %{"working_directory" => cwd, "exceptions" => [exception]}
        {:error, _reason} -> %{"exceptions" => [exception]}
      end

    Map.merge(document, %{"fault" => true, "cause" => cause})
  end

  defp stack_frame({module, function, arity_or_args, location}) do
    location
    |> frame_location()
    |> Map.put("label", Exception.format_mfa(module, function, arity_or_args))
  end

  defp stack_frame({fun, arity_or_args, location}) do
    location
    |> frame_location()
    |> Map.put("label", Exception.format_fa(fun, arity_or_args))
  end

  defp frame_location(location) do
    for {key, value} <- [{"path", location[:file]}, {"line", location[:line]}],
        value != nil,
        into: %{},
        do: {key, if(is_list(value), do: List.to_string(value), else: value)}
  end

  defp describe(reason) when is_binary(reason) do
    reason
  end

  defp describe(reason) do
    inspect(reason)
  end

  # Helpers

  # 64 bits, as 16 hexadecimal digits. `:rand` rather than `:crypto`, which
  # would have to be started for this alone.
  defp new_id do
    8 |> :rand.bytes() |> Base.encode16(case: :lower)
  end

  # Seconds since the epoch, with microseconds.
  defp now do
    System.os_time(:microsecond) / 1_000_000
  end
end
