defmodule AWS.Lambda.Runtime.Events.SNS do
  @moduledoc """
  Notifications from an SNS topic, usually one per invocation.

      def handle(%SNS{records: [%SNS.Message{subject: subject, message: message}]}, _context, _state) do
        notify(subject, message)
      end

  The message is left as the string it was published as.
  """

  alias AWS.Lambda.Runtime.Events

  ## Types

  @type t :: %__MODULE__{records: [__MODULE__.Message.t()], event: map()}

  ## Module attributes

  defstruct records: [], event: %{}

  defmodule Message do
    @moduledoc """
    A notification of an `AWS.Lambda.Runtime.Events.SNS` event.

      * `:message`, `:subject` - as published.
      * `:message_attributes` - name to value.
      * `:timestamp` - when it was published, a `DateTime`.
      * `:message_id`, `:topic_arn`, `:subscription_arn`, `:type`.
    """

    @type t :: %__MODULE__{
            message_id: String.t(),
            topic_arn: String.t() | nil,
            subscription_arn: String.t() | nil,
            subject: String.t() | nil,
            message: String.t(),
            message_attributes: %{String.t() => String.t()},
            timestamp: DateTime.t() | nil,
            type: String.t() | nil
          }

    defstruct [
      :message_id,
      :topic_arn,
      :subscription_arn,
      :subject,
      :message,
      :timestamp,
      :type,
      message_attributes: %{}
    ]
  end

  ## Public functions

  @doc "Decodes an SNS event. See `AWS.Lambda.Runtime.Events.decode/1`."
  @spec from_event(map()) :: {:ok, t()} | {:error, String.t()}
  def from_event(%{"Records" => records} = event) do
    {:ok, %__MODULE__{records: Enum.map(records, &message/1), event: event}}
  end

  ## Private functions

  defp message(record) do
    sns = record["Sns"] || %{}

    %Message{
      message_id: sns["MessageId"],
      topic_arn: sns["TopicArn"],
      subscription_arn: record["EventSubscriptionArn"],
      subject: sns["Subject"],
      message: sns["Message"],
      message_attributes:
        Map.new(sns["MessageAttributes"] || %{}, fn
          {name, %{"Value" => value}} -> {name, value}
          {name, other} -> {name, other}
        end),
      timestamp: Events.datetime(sns["Timestamp"]),
      type: sns["Type"]
    }
  end
end
