if Code.ensure_loaded?(:telemetry) do
  defmodule AWS.Lambda.Runtime.XRay.Telemetry do
    @moduledoc """
    Records X-Ray subsegments from `:telemetry` events, so the queries, HTTP
    calls and spans a handler makes are traced without wrapping each of them in
    `AWS.Lambda.Runtime.XRay.subsegment/3`.

    Only compiled when the function depends on `:telemetry`, as it does through
    Ecto, Finch or Req. Attach the handlers once, from the function's
    application:

        def start(_type, _args) do
          AWS.Lambda.Runtime.XRay.Telemetry.attach(
            ecto: [:my_app, :repo],
            finch: true,
            spans: [[:my_app, :billing, :charge]]
          )

          Supervisor.start_link(children, strategy: :one_for_one)
        end

    ## Events

      * `:ecto` - a repo's telemetry prefix (`[:my_app, :repo]` for
        `MyApp.Repo`, unless its `:telemetry_prefix` says otherwise), or a list
        of them. Each `[..., :query]` event becomes a subsegment named after the
        repo, with the query as its `sql.sanitized_query` (parameters are sent
        apart from it, so they aren't recorded) and its queue, query and decode
        times as metadata. A query returning an error is a fault.
      * `:finch` - `true` to record each `Finch` request, which includes those
        made by `Req`, as a subsegment named after the host, with the method,
        the URL (without its query string, which may carry credentials) and
        the response status.
      * `:spans` - event prefixes of `:telemetry.span/3` calls, each recorded
        as a subsegment named after its prefix, e.g. `my_app.billing.charge`.
        A `{prefix, opts}` tuple sets the `:name`, a string or a function of
        the start event's metadata, and the `:namespace`.

    Subsegments nest like those of `AWS.Lambda.Runtime.XRay.subsegment/3`:
    telemetry calls its handlers in the process emitting the event, so a query
    run inside a span is recorded as its child. Like them too, nothing is
    recorded when the invocation isn't sampled.
    """

    alias AWS.Lambda.Runtime.XRay

    ## Module attributes

    @finch_events [
      [:finch, :request, :start],
      [:finch, :request, :stop],
      [:finch, :request, :exception]
    ]

    @database_types %{
      Ecto.Adapters.Postgres => "PostgreSQL",
      Ecto.Adapters.MyXQL => "MySQL",
      Ecto.Adapters.SQLite3 => "SQLite",
      Ecto.Adapters.Tds => "SQL Server"
    }

    ## Public functions

    @doc """
    Attaches the handlers turning the given events into subsegments. See the
    moduledoc for the options.

    Returns `{:error, :already_exists}` when the handler of one of them is
    already attached.
    """
    @spec attach(keyword()) :: :ok | {:error, :already_exists}
    def attach(opts) do
      opts = Keyword.validate!(opts, ecto: [], finch: false, spans: [])

      handlers =
        Enum.map(repo_prefixes(opts[:ecto]), &ecto_handler/1) ++
          if(opts[:finch], do: [finch_handler()], else: []) ++
          Enum.map(opts[:spans], &span_handler/1)

      Enum.reduce_while(handlers, :ok, fn {id, events, config}, :ok ->
        case :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, config) do
          :ok -> {:cont, :ok}
          {:error, :already_exists} = error -> {:halt, error}
        end
      end)
    end

    @doc "Detaches every handler attached by `attach/1`."
    @spec detach() :: :ok
    def detach do
      for %{id: {__MODULE__, _events} = id} <- :telemetry.list_handlers([]) do
        :telemetry.detach(id)
      end

      :ok
    end

    @doc false
    def handle_event([_ | _] = event, _measurements, metadata, %{type: :span} = config) do
      case List.last(event) do
        :start ->
          XRay.begin_subsegment(span_name(config.name, metadata), namespace: config.namespace)

        :stop ->
          XRay.end_subsegment()

        :exception ->
          XRay.end_subsegment(exception: exception(metadata))
      end
    end

    def handle_event(_event, measurements, metadata, %{type: :ecto}) do
      duration = measurements[:total_time] || 0

      XRay.begin_subsegment(repo_name(metadata[:repo]),
        namespace: "remote",
        start_time: System.os_time() - duration,
        sql: sql(metadata),
        metadata: query_metadata(measurements, metadata)
      )

      case metadata[:result] do
        {:error, reason} -> XRay.end_subsegment(exception: {:error, reason, []})
        _result -> XRay.end_subsegment()
      end
    end

    def handle_event([:finch, :request, :start], _measurements, metadata, %{type: :finch}) do
      request = metadata[:request] || %{}

      XRay.begin_subsegment(host(request),
        namespace: "remote",
        http: %{request: reject_nil(%{method: Map.get(request, :method), url: url(request)})}
      )
    end

    def handle_event([:finch, :request, :stop], _measurements, metadata, %{type: :finch}) do
      case metadata[:result] do
        {:ok, %{status: status}} when is_integer(status) ->
          XRay.end_subsegment(http: %{response: %{status: status}})

        {:error, reason} ->
          XRay.end_subsegment(exception: {:error, reason, []})

        _result ->
          XRay.end_subsegment()
      end
    end

    def handle_event([:finch, :request, :exception], _measurements, metadata, %{type: :finch}) do
      XRay.end_subsegment(exception: exception(metadata))
    end

    ## Private functions

    # Handlers

    defp ecto_handler(prefix) do
      event = prefix ++ [:query]

      {{__MODULE__, event}, [event], %{type: :ecto}}
    end

    defp finch_handler do
      {{__MODULE__, [:finch, :request]}, @finch_events, %{type: :finch}}
    end

    defp span_handler({prefix, opts}) when is_list(prefix) do
      opts = Keyword.validate!(opts, [:name, :namespace])

      config = %{
        type: :span,
        name: opts[:name] || Enum.join(prefix, "."),
        namespace: opts[:namespace]
      }

      {{__MODULE__, prefix}, Enum.map([:start, :stop, :exception], &(prefix ++ [&1])), config}
    end

    defp span_handler(prefix) when is_list(prefix) do
      span_handler({prefix, []})
    end

    # A single prefix, or a list of them.
    defp repo_prefixes([]) do
      []
    end

    defp repo_prefixes([name | _rest] = prefix) when is_atom(name) do
      [prefix]
    end

    defp repo_prefixes(prefixes) when is_list(prefixes) do
      prefixes
    end

    # Spans

    defp span_name(name, metadata) when is_function(name, 1) do
      name.(metadata)
    end

    defp span_name(name, _metadata) when is_binary(name) do
      name
    end

    defp exception(%{kind: kind, reason: reason, stacktrace: stacktrace}) do
      {kind, reason, stacktrace}
    end

    # Ecto

    defp repo_name(nil) do
      "Ecto"
    end

    defp repo_name(repo) do
      inspect(repo)
    end

    defp sql(metadata) do
      database_type =
        with repo when is_atom(repo) and not is_nil(repo) <- metadata[:repo],
             true <- function_exported?(repo, :__adapter__, 0) do
          @database_types[repo.__adapter__()]
        else
          _unknown -> nil
        end

      reject_nil(%{sanitized_query: metadata[:query], database_type: database_type})
    end

    defp query_metadata(measurements, metadata) do
      timings =
        for {key, native} <- Map.take(measurements, [:queue_time, :query_time, :decode_time]),
            is_integer(native),
            into: %{},
            do: {"#{key}_ms", System.convert_time_unit(native, :native, :microsecond) / 1000}

      case metadata[:source] do
        nil -> timings
        source -> Map.put(timings, "source", source)
      end
    end

    # Finch

    defp host(%{host: host}) when is_binary(host) do
      host
    end

    defp host(_request) do
      "HTTP"
    end

    defp url(%{scheme: scheme, host: host, port: port, path: path}) do
      port = if {scheme, port} in [{:http, 80}, {:https, 443}], do: "", else: ":#{port}"

      "#{scheme}://#{host}#{port}#{path}"
    end

    defp url(_request) do
      nil
    end

    # Helpers

    defp reject_nil(map) do
      Map.reject(map, fn {_key, value} -> is_nil(value) end)
    end
  end
end
