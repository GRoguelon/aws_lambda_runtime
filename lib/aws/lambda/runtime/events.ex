defmodule AWS.Lambda.Runtime.Events do
  @moduledoc """
  Decodes the events AWS services invoke a function with, so
  `c:AWS.Lambda.Runtime.Handler.handle/3` receives them ready to use:

  | Source | Struct |
  |---|---|
  | SQS | `AWS.Lambda.Runtime.Events.SQS` |
  | SNS | `AWS.Lambda.Runtime.Events.SNS` |
  | S3 | `AWS.Lambda.Runtime.Events.S3` |
  | EventBridge | `AWS.Lambda.Runtime.Events.EventBridge` |
  | Kinesis | `AWS.Lambda.Runtime.Events.Kinesis` |
  | DynamoDB Streams | `AWS.Lambda.Runtime.Events.DynamoDB` |

  Each struct keeps the invocation's event in `:event`. Any other event is
  left as it is.

  ## Partial batch failures

  SQS, Kinesis and DynamoDB Streams deliver records in batches. A handler
  returning `{:error, reason}`, or raising, has the whole batch retried;
  returning `{:retry, failed}`, with the records that failed or their IDs,
  has only those retried:

      def handle(%SQS{records: messages}, _context, _state) do
        {:retry, Enum.reject(messages, &(process(&1) == :ok))}
      end

  The event source mapping must have `ReportBatchItemFailures` among its
  function response types. `{:retry, []}` reports the whole batch as
  processed.
  """

  alias AWS.Lambda.Runtime.Events.DynamoDB
  alias AWS.Lambda.Runtime.Events.EventBridge
  alias AWS.Lambda.Runtime.Events.Kinesis
  alias AWS.Lambda.Runtime.Events.S3
  alias AWS.Lambda.Runtime.Events.SNS
  alias AWS.Lambda.Runtime.Events.SQS

  ## Public functions

  @doc """
  Decodes an invocation's event into the struct of its source.

  Returns `:error` when the event comes from none of them, and
  `{:error, message}` when it does but can't be decoded.
  """
  @spec decode(term()) :: {:ok, struct()} | {:error, String.t()} | :error
  def decode(%{"Records" => [%{"eventSource" => "aws:sqs"} | _rest]} = event) do
    SQS.from_event(event)
  end

  def decode(%{"Records" => [%{"EventSource" => "aws:sns"} | _rest]} = event) do
    SNS.from_event(event)
  end

  def decode(%{"Records" => [%{"eventSource" => "aws:s3"} | _rest]} = event) do
    S3.from_event(event)
  end

  def decode(%{"Records" => [%{"eventSource" => "aws:kinesis"} | _rest]} = event) do
    Kinesis.from_event(event)
  end

  def decode(%{"Records" => [%{"eventSource" => "aws:dynamodb"} | _rest]} = event) do
    DynamoDB.from_event(event)
  end

  def decode(%{"detail-type" => type, "source" => source, "detail" => _detail} = event)
      when is_binary(type) and is_binary(source) do
    EventBridge.from_event(event)
  end

  def decode(_event) do
    :error
  end

  @doc """
  The partial batch response for `{:retry, failed}`, where `failed` lists
  records or their IDs. See the moduledoc.
  """
  @spec batch_item_failures([struct() | String.t()]) :: {:ok, map()} | {:error, String.t()}
  def batch_item_failures(failed) when is_list(failed) do
    Enum.reduce_while(failed, {:ok, []}, fn item, {:ok, ids} ->
      case item_identifier(item) do
        {:ok, id} -> {:cont, {:ok, [%{"itemIdentifier" => id} | ids]}}
        :error -> {:halt, {:error, "cannot retry #{inspect(item)}: not a record nor an ID"}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, %{"batchItemFailures" => Enum.reverse(ids)}}
      error -> error
    end
  end

  def batch_item_failures(failed) do
    {:error, "{:retry, failed} takes a list, got: #{inspect(failed)}"}
  end

  @doc false
  def datetime(nil) do
    nil
  end

  def datetime(seconds) when is_number(seconds) do
    case DateTime.from_unix(round(seconds * 1000), :millisecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  def datetime(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  ## Private functions

  defp item_identifier(id) when is_binary(id), do: {:ok, id}
  defp item_identifier(%SQS.Message{message_id: id}), do: {:ok, id}
  defp item_identifier(%Kinesis.Record{sequence_number: id}), do: {:ok, id}
  defp item_identifier(%DynamoDB.Record{sequence_number: id}), do: {:ok, id}
  defp item_identifier(_item), do: :error
end
