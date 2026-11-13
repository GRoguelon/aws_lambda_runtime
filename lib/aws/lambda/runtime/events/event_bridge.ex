defmodule AWS.Lambda.Runtime.Events.EventBridge do
  @moduledoc """
  An event delivered by an EventBridge rule or schedule.

      def handle(%EventBridge{source: "myapp.orders", detail_type: "OrderPlaced", detail: order}, _context, _state) do
        fulfil(order)
      end

  `:detail` is the event's payload, decoded from JSON.
  """

  alias AWS.Lambda.Runtime.Events

  ## Types

  @type t :: %__MODULE__{
          id: String.t() | nil,
          source: String.t(),
          detail_type: String.t(),
          detail: term(),
          time: DateTime.t() | nil,
          region: String.t() | nil,
          account: String.t() | nil,
          resources: [String.t()],
          event: map()
        }

  ## Module attributes

  defstruct [
    :id,
    :source,
    :detail_type,
    :detail,
    :time,
    :region,
    :account,
    resources: [],
    event: %{}
  ]

  ## Public functions

  @doc "Decodes an EventBridge event. See `AWS.Lambda.Runtime.Events.decode/1`."
  @spec from_event(map()) :: {:ok, t()} | {:error, String.t()}
  def from_event(event) do
    {:ok,
     %__MODULE__{
       id: event["id"],
       source: event["source"],
       detail_type: event["detail-type"],
       detail: event["detail"],
       time: Events.datetime(event["time"]),
       region: event["region"],
       account: event["account"],
       resources: event["resources"] || [],
       event: event
     }}
  end
end
