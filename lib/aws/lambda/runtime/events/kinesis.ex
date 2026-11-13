defmodule AWS.Lambda.Runtime.Events.Kinesis do
  @moduledoc """
  A batch of records from a Kinesis data stream.

      def handle(%Kinesis{records: records}, _context, _state) do
        for %Kinesis.Record{data: data} <- records, do: process(data)
        :ok
      end

  The data is decoded from base64, the bytes as they were put. Retry part of
  the batch with `{:retry, failed}`, see `AWS.Lambda.Runtime.Events`.
  """

  alias AWS.Lambda.Runtime.Events

  ## Types

  @type t :: %__MODULE__{records: [__MODULE__.Record.t()], event: map()}

  ## Module attributes

  defstruct records: [], event: %{}

  defmodule Record do
    @moduledoc """
    A record of an `AWS.Lambda.Runtime.Events.Kinesis` batch.

      * `:data` - the bytes as they were put.
      * `:sequence_number` - what `{:retry, failed}` identifies it by.
      * `:partition_key`.
      * `:arrival_time` - when Kinesis received it, a `DateTime`.
      * `:event_id`, `:event_source_arn`, `:region`.
    """

    @type t :: %__MODULE__{
            data: binary(),
            partition_key: String.t() | nil,
            sequence_number: String.t(),
            arrival_time: DateTime.t() | nil,
            event_id: String.t() | nil,
            event_source_arn: String.t() | nil,
            region: String.t() | nil
          }

    defstruct [
      :data,
      :partition_key,
      :sequence_number,
      :arrival_time,
      :event_id,
      :event_source_arn,
      :region
    ]
  end

  ## Public functions

  @doc "Decodes a Kinesis event. See `AWS.Lambda.Runtime.Events.decode/1`."
  @spec from_event(map()) :: {:ok, t()} | {:error, String.t()}
  def from_event(%{"Records" => records} = event) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case record(record) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, %__MODULE__{records: Enum.reverse(records), event: event}}
      error -> error
    end
  end

  ## Private functions

  defp record(record) do
    kinesis = record["kinesis"] || %{}

    case Base.decode64(kinesis["data"] || "") do
      {:ok, data} ->
        {:ok,
         %Record{
           data: data,
           partition_key: kinesis["partitionKey"],
           sequence_number: kinesis["sequenceNumber"],
           arrival_time: Events.datetime(kinesis["approximateArrivalTimestamp"]),
           event_id: record["eventID"],
           event_source_arn: record["eventSourceARN"],
           region: record["awsRegion"]
         }}

      :error ->
        record =
          case kinesis["sequenceNumber"] do
            nil -> "a Kinesis record"
            sequence_number -> "Kinesis record #{sequence_number}"
          end

        {:error, "the data of #{record} is not valid base64"}
    end
  end
end
