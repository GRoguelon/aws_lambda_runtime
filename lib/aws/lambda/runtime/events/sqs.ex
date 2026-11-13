defmodule AWS.Lambda.Runtime.Events.SQS do
  @moduledoc """
  A batch of messages from an SQS queue.

      def handle(%SQS{records: messages}, _context, _state) do
        for %SQS.Message{body: body} <- messages, do: process(body)
        :ok
      end

  The body is left as the string it was sent as: decode it as its sender
  encoded it. Retry part of the batch with `{:retry, failed}`, see
  `AWS.Lambda.Runtime.Events`.
  """

  ## Types

  @type t :: %__MODULE__{records: [__MODULE__.Message.t()], event: map()}

  ## Module attributes

  defstruct records: [], event: %{}

  defmodule Message do
    @moduledoc """
    A message of an `AWS.Lambda.Runtime.Events.SQS` batch.

      * `:message_id` - what `{:retry, failed}` identifies it by.
      * `:body` - as sent.
      * `:attributes` - SQS's own, such as `"ApproximateReceiveCount"`.
      * `:message_attributes` - the sender's, name to value: a string, or the
        decoded bytes of a binary attribute.
      * `:receipt_handle`, `:md5_of_body`, `:event_source_arn`, `:region`.
    """

    @type t :: %__MODULE__{
            message_id: String.t(),
            receipt_handle: String.t() | nil,
            body: String.t(),
            attributes: map(),
            message_attributes: %{String.t() => String.t()},
            md5_of_body: String.t() | nil,
            event_source_arn: String.t() | nil,
            region: String.t() | nil
          }

    defstruct [
      :message_id,
      :receipt_handle,
      :body,
      :md5_of_body,
      :event_source_arn,
      :region,
      attributes: %{},
      message_attributes: %{}
    ]
  end

  ## Public functions

  @doc "Decodes an SQS event. See `AWS.Lambda.Runtime.Events.decode/1`."
  @spec from_event(map()) :: {:ok, t()} | {:error, String.t()}
  def from_event(%{"Records" => records} = event) do
    {:ok, %__MODULE__{records: Enum.map(records, &message/1), event: event}}
  end

  ## Private functions

  defp message(record) do
    %Message{
      message_id: record["messageId"],
      receipt_handle: record["receiptHandle"],
      body: record["body"],
      attributes: record["attributes"] || %{},
      message_attributes: message_attributes(record["messageAttributes"]),
      md5_of_body: record["md5OfBody"],
      event_source_arn: record["eventSourceARN"],
      region: record["awsRegion"]
    }
  end

  defp message_attributes(nil) do
    %{}
  end

  defp message_attributes(attributes) do
    Map.new(attributes, fn
      {name, %{"stringValue" => value}} when is_binary(value) ->
        {name, value}

      {name, %{"binaryValue" => value}} when is_binary(value) ->
        case Base.decode64(value) do
          {:ok, bytes} -> {name, bytes}
          :error -> {name, value}
        end

      {name, other} ->
        {name, other}
    end)
  end
end
