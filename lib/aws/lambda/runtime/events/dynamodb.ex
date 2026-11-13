defmodule AWS.Lambda.Runtime.Events.DynamoDB do
  @moduledoc """
  A batch of changes from a DynamoDB stream.

      def handle(%DynamoDB{records: records}, _context, _state) do
        for %DynamoDB.Record{event_name: "INSERT", new_image: item} <- records, do: notify(item)
        :ok
      end

  Keys and images are plain maps: DynamoDB's typed values are decoded, so
  `%{"name" => %{"S" => "Ada"}, "age" => %{"N" => "36"}}` reads
  `%{"name" => "Ada", "age" => 36}`. Numbers become integers or floats,
  binaries are decoded from base64, and sets become lists.

  Retry part of the batch with `{:retry, failed}`, see
  `AWS.Lambda.Runtime.Events`.
  """

  alias AWS.Lambda.Runtime.Events

  ## Types

  @type t :: %__MODULE__{records: [__MODULE__.Record.t()], event: map()}

  ## Module attributes

  defstruct records: [], event: %{}

  defmodule Record do
    @moduledoc """
    A change of an `AWS.Lambda.Runtime.Events.DynamoDB` batch.

      * `:event_name` - `"INSERT"`, `"MODIFY"` or `"REMOVE"`.
      * `:keys`, `:new_image`, `:old_image` - plain maps, the images only
        when the stream's view type includes them.
      * `:sequence_number` - what `{:retry, failed}` identifies it by.
      * `:created_at` - when the change was made, a `DateTime`.
      * `:event_id`, `:event_source_arn`, `:region`.
    """

    @type t :: %__MODULE__{
            event_name: String.t(),
            keys: map(),
            new_image: map() | nil,
            old_image: map() | nil,
            sequence_number: String.t(),
            created_at: DateTime.t() | nil,
            event_id: String.t() | nil,
            event_source_arn: String.t() | nil,
            region: String.t() | nil
          }

    defstruct [
      :event_name,
      :new_image,
      :old_image,
      :sequence_number,
      :created_at,
      :event_id,
      :event_source_arn,
      :region,
      keys: %{}
    ]
  end

  ## Public functions

  @doc "Decodes a DynamoDB Streams event. See `AWS.Lambda.Runtime.Events.decode/1`."
  @spec from_event(map()) :: {:ok, t()} | {:error, String.t()}
  def from_event(%{"Records" => records} = event) do
    {:ok, %__MODULE__{records: Enum.map(records, &record/1), event: event}}
  rescue
    ArgumentError -> {:error, "a DynamoDB stream record holds a value that can't be decoded"}
  end

  @doc """
  Decodes a map of DynamoDB typed values, such as an item's attributes, into
  a plain map.
  """
  @spec decode_item(map() | nil) :: map() | nil
  def decode_item(nil) do
    nil
  end

  def decode_item(item) when is_map(item) do
    Map.new(item, fn {name, value} -> {name, decode_value(value)} end)
  end

  ## Private functions

  defp record(record) do
    dynamodb = record["dynamodb"] || %{}

    %Record{
      event_name: record["eventName"],
      keys: decode_item(dynamodb["Keys"]) || %{},
      new_image: decode_item(dynamodb["NewImage"]),
      old_image: decode_item(dynamodb["OldImage"]),
      sequence_number: dynamodb["SequenceNumber"],
      created_at: Events.datetime(dynamodb["ApproximateCreationDateTime"]),
      event_id: record["eventID"],
      event_source_arn: record["eventSourceARN"],
      region: record["awsRegion"]
    }
  end

  defp decode_value(%{"S" => string}), do: string
  defp decode_value(%{"N" => number}), do: number(number)
  defp decode_value(%{"B" => binary}), do: Base.decode64!(binary)
  defp decode_value(%{"BOOL" => boolean}), do: boolean
  defp decode_value(%{"NULL" => true}), do: nil
  defp decode_value(%{"L" => list}), do: Enum.map(list, &decode_value/1)
  defp decode_value(%{"M" => map}), do: decode_item(map)
  defp decode_value(%{"SS" => strings}), do: strings
  defp decode_value(%{"NS" => numbers}), do: Enum.map(numbers, &number/1)
  defp decode_value(%{"BS" => binaries}), do: Enum.map(binaries, &Base.decode64!/1)

  defp decode_value(other) do
    raise ArgumentError, "unknown DynamoDB value: #{inspect(other)}"
  end

  defp number(string) do
    case Integer.parse(string) do
      {integer, ""} ->
        integer

      _not_an_integer ->
        case Float.parse(string) do
          {float, ""} -> float
          _invalid -> raise ArgumentError, "invalid DynamoDB number: #{inspect(string)}"
        end
    end
  end
end
