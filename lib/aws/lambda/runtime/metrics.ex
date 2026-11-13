defmodule AWS.Lambda.Runtime.Metrics do
  @moduledoc """
  Publishes CloudWatch metrics through the Embedded Metric Format (EMF).

  Each call writes one line of JSON to the function's output. CloudWatch Logs
  reads it from the function's log group and publishes its metrics: no
  CloudWatch API call, no network round trip during the invocation, and no
  permission beyond the logs the function already writes.

      Metrics.count("MyApp", "OrdersPlaced")

      Metrics.emit("MyApp", %{"OrderTotal" => {42.5, :none}, "Items" => 3},
        dimensions: %{"Channel" => "web"},
        properties: %{"orderId" => order.id}
      )

      order = Metrics.timing("MyApp", "ChargeLatency", fn -> charge(order) end)

  ## Metrics

  A metric's value is a number, a list of up to 100 numbers (to publish many
  values at once, such as every query's time), or `{value, unit}`. The unit
  is a CloudWatch unit, given as a string (`"Milliseconds"`) or an atom
  (`:milliseconds`, `:count`, `:bytes`, `:percent`…). Without one, the metric
  has none.

  ## Options

    * `:dimensions` - a map of dimension names to values, the metrics'
      single dimension set. Each distinct combination of values is a metric
      of its own, billed as such: keep high-cardinality values, such as user
      IDs, in `:properties`.
    * `:properties` - a map of other values, recorded in the line but not
      published as metrics, which CloudWatch Logs Insights can search.

  During an invocation, the line also carries its `requestId`.
  """

  ## Module attributes

  @units %{
    seconds: "Seconds",
    microseconds: "Microseconds",
    milliseconds: "Milliseconds",
    bytes: "Bytes",
    kilobytes: "Kilobytes",
    megabytes: "Megabytes",
    gigabytes: "Gigabytes",
    terabytes: "Terabytes",
    bits: "Bits",
    kilobits: "Kilobits",
    megabits: "Megabits",
    gigabits: "Gigabits",
    terabits: "Terabits",
    percent: "Percent",
    count: "Count",
    bytes_per_second: "Bytes/Second",
    kilobytes_per_second: "Kilobytes/Second",
    megabytes_per_second: "Megabytes/Second",
    gigabytes_per_second: "Gigabytes/Second",
    terabytes_per_second: "Terabytes/Second",
    bits_per_second: "Bits/Second",
    kilobits_per_second: "Kilobits/Second",
    megabits_per_second: "Megabits/Second",
    gigabits_per_second: "Gigabits/Second",
    terabits_per_second: "Terabits/Second",
    count_per_second: "Count/Second",
    none: "None"
  }

  # CloudWatch's limits for one line.
  @max_metrics 100
  @max_dimensions 30
  @max_values 100

  ## Public functions

  @doc """
  Publishes `metrics`, a map of metric names to values, in `namespace`.
  See the moduledoc for the values and options.

  Raises `ArgumentError` for a line CloudWatch wouldn't accept.
  """
  @spec emit(String.t(), %{String.t() => term()}, keyword()) :: :ok
  def emit(namespace, metrics, opts \\ [])
      when is_binary(namespace) and is_map(metrics) and map_size(metrics) > 0 do
    opts = Keyword.validate!(opts, dimensions: %{}, properties: %{})

    # CloudWatch only takes strings as dimension values.
    dimensions =
      Map.new(opts[:dimensions], fn {name, value} -> {to_string(name), to_string(value)} end)

    if map_size(metrics) > @max_metrics do
      raise ArgumentError, "at most #{@max_metrics} metrics per line, got #{map_size(metrics)}"
    end

    if map_size(dimensions) > @max_dimensions do
      raise ArgumentError,
            "at most #{@max_dimensions} dimensions per line, got #{map_size(dimensions)}"
    end

    {definitions, values} =
      Enum.reduce(metrics, {[], %{}}, fn {name, value}, {definitions, values} ->
        name = to_string(name)
        {value, unit} = metric(name, value)

        definition =
          if unit, do: %{"Name" => name, "Unit" => unit}, else: %{"Name" => name}

        {[definition | definitions], Map.put(values, name, value)}
      end)

    line =
      opts[:properties]
      |> stringify()
      |> put_request_id()
      |> Map.merge(dimensions)
      |> Map.merge(values)
      |> Map.put("_aws", %{
        "Timestamp" => System.system_time(:millisecond),
        "CloudWatchMetrics" => [
          %{
            "Namespace" => namespace,
            "Dimensions" => [Map.keys(dimensions)],
            "Metrics" => Enum.reverse(definitions)
          }
        ]
      })

    IO.write([JSON.encode_to_iodata!(line), ?\n])
  end

  @doc "Publishes `value` (1 by default) for the count metric `name`."
  @spec count(String.t(), String.t(), number(), keyword()) :: :ok
  def count(namespace, name, value \\ 1, opts \\ []) when is_number(value) do
    emit(namespace, %{name => {value, :count}}, opts)
  end

  @doc """
  Calls `fun`, publishes how long it took in milliseconds as the metric
  `name`, and returns its result. Nothing is published if `fun` raises,
  throws or exits.
  """
  @spec timing(String.t(), String.t(), (-> result), keyword()) :: result when result: term()
  def timing(namespace, name, fun, opts \\ []) when is_function(fun, 0) do
    start = System.monotonic_time()
    result = fun.()
    elapsed = System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

    emit(namespace, %{name => {elapsed / 1000, :milliseconds}}, opts)

    result
  end

  ## Private functions

  defp metric(name, {value, unit}) do
    {value(name, value), unit(name, unit)}
  end

  defp metric(name, value) do
    {value(name, value), nil}
  end

  defp value(_name, value) when is_number(value) do
    value
  end

  defp value(name, values)
       when is_list(values) and values != [] and length(values) <= @max_values do
    if Enum.all?(values, &is_number/1) do
      values
    else
      raise ArgumentError, "the values of metric #{inspect(name)} must be numbers"
    end
  end

  defp value(name, value) do
    raise ArgumentError,
          "metric #{inspect(name)} must be a number or a list of 1 to #{@max_values} numbers, " <>
            "got: #{inspect(value)}"
  end

  defp unit(_name, unit) when is_binary(unit) do
    unit
  end

  defp unit(name, unit) when is_atom(unit) do
    Map.get(@units, unit) ||
      raise ArgumentError, "unknown CloudWatch unit #{inspect(unit)} for metric #{inspect(name)}"
  end

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp put_request_id(properties) do
    case Logger.metadata()[:request_id] do
      request_id when is_binary(request_id) -> Map.put_new(properties, "requestId", request_id)
      _none -> properties
    end
  end
end
