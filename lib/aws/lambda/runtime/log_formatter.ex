defmodule AWS.Lambda.Runtime.LogFormatter do
  @moduledoc """
  `:logger` formatter writing each log event as one line of JSON, the format
  Lambda expects when the function's log format is `JSON`.

      {"timestamp":"2026-11-13T15:41:03.123Z","level":"INFO","requestId":"8f5…","message":"hello","module":"MyApp","line":12}

  `timestamp`, `level`, `message` and, during an invocation, `requestId` are
  always present; the event's metadata follows, minus the VM's internal keys
  (pid, group leader, `mfa`…). A multi-line message, such as a stack trace,
  stays on one line, so it is a single CloudWatch Logs event.

  Installed by `AWS.Lambda.Runtime.Logging.configure/1`; it can also be set
  explicitly:

      config :logger, :default_handler, formatter: {AWS.Lambda.Runtime.LogFormatter, %{}}
  """

  ## Module attributes

  # Metadata the VM or Logger adds for its own use, or that the fixed fields
  # already carry.
  @internal_metadata [
    :time,
    :gl,
    :pid,
    :mfa,
    :domain,
    :report_cb,
    :error_logger,
    :logger_formatter,
    :callers,
    :ancestors,
    :crash_reason,
    :request_id
  ]

  ## Public functions

  @doc """
  Formats `event` as a line of JSON. Called by `:logger`; `config` is unused.
  """
  @spec format(:logger.log_event(), :logger.formatter_config()) :: iodata()
  def format(%{level: level, meta: meta} = event, _config) do
    fields = %{
      "timestamp" => timestamp(meta),
      "level" => level(level),
      "message" => message(event)
    }

    fields =
      case meta do
        %{request_id: request_id} when is_binary(request_id) ->
          Map.put(fields, "requestId", request_id)

        _meta ->
          fields
      end

    [fields |> Map.merge(metadata(meta)) |> JSON.encode_to_iodata!(), ?\n]
  rescue
    # A formatter that raises gets its handler removed: log something useful
    # rather than nothing.
    exception ->
      fallback = %{
        "level" => "ERROR",
        "message" =>
          "could not format log event: #{Exception.message(exception)}: #{inspect(event)}"
      }

      [JSON.encode_to_iodata!(fallback), ?\n]
  end

  @doc """
  Maps a `Logger` level to the name Lambda uses (`TRACE`, `DEBUG`, `INFO`,
  `WARN`, `ERROR` or `FATAL`).
  """
  @spec level(Logger.level()) :: String.t()
  def level(:debug), do: "DEBUG"
  def level(level) when level in [:info, :notice], do: "INFO"
  def level(:warning), do: "WARN"
  def level(:error), do: "ERROR"
  def level(level) when level in [:critical, :alert, :emergency], do: "FATAL"

  ## Private functions

  defp timestamp(%{time: time}) do
    time |> div(1000) |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  end

  defp timestamp(_meta) do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  # Rendered like the default formatter does, Erlang reports included.
  defp message(event) do
    truncate = Application.get_env(:logger, :truncate, 8096)

    event
    |> Logger.Formatter.format_event(truncate)
    |> IO.chardata_to_string()
  end

  defp metadata(meta) do
    for {key, value} <- meta, key not in @internal_metadata, into: %{} do
      {Atom.to_string(key), json_value(value)}
    end
  end

  # Metadata can hold any term: keep what JSON represents as is, inspect the
  # rest (pids, tuples, maps…).
  defp json_value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value)
  end

  defp json_value(value) when is_number(value) or is_boolean(value) or is_nil(value) do
    value
  end

  defp json_value(value) when is_atom(value) do
    case Atom.to_string(value) do
      "Elixir." <> _module -> inspect(value)
      name -> name
    end
  end

  defp json_value(value) when is_list(value) do
    if List.ascii_printable?(value), do: List.to_string(value), else: inspect(value)
  end

  defp json_value(value) do
    inspect(value)
  end
end
