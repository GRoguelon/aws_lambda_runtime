defmodule AWS.Lambda.Runtime.Events.S3 do
  @moduledoc """
  Notifications of changes to objects of an S3 bucket.

      def handle(%S3{records: records}, _context, _state) do
        for %S3.Record{event_name: "ObjectCreated:" <> _, bucket: bucket, key: key} <- records do
          index(bucket, key)
        end

        :ok
      end

  The key is decoded: S3 sends it URL-encoded, a space as `+`.
  """

  alias AWS.Lambda.Runtime.Events

  ## Types

  @type t :: %__MODULE__{records: [__MODULE__.Record.t()], event: map()}

  ## Module attributes

  defstruct records: [], event: %{}

  defmodule Record do
    @moduledoc """
    A change of an `AWS.Lambda.Runtime.Events.S3` event.

      * `:event_name` - `"ObjectCreated:Put"`, `"ObjectRemoved:Delete"`…
      * `:bucket`, `:key` - the object, its key decoded.
      * `:size`, `:etag`, `:version_id` - when S3 sends them.
      * `:event_time` - a `DateTime`.
      * `:region`, `:bucket_arn`, `:sequencer`.
    """

    @type t :: %__MODULE__{
            event_name: String.t(),
            event_time: DateTime.t() | nil,
            region: String.t() | nil,
            bucket: String.t(),
            bucket_arn: String.t() | nil,
            key: String.t(),
            size: non_neg_integer() | nil,
            etag: String.t() | nil,
            version_id: String.t() | nil,
            sequencer: String.t() | nil
          }

    defstruct [
      :event_name,
      :event_time,
      :region,
      :bucket,
      :bucket_arn,
      :key,
      :size,
      :etag,
      :version_id,
      :sequencer
    ]
  end

  ## Public functions

  @doc "Decodes an S3 event. See `AWS.Lambda.Runtime.Events.decode/1`."
  @spec from_event(map()) :: {:ok, t()} | {:error, String.t()}
  def from_event(%{"Records" => records} = event) do
    {:ok, %__MODULE__{records: Enum.map(records, &record/1), event: event}}
  rescue
    ArgumentError -> {:error, "an S3 object key is not validly URL-encoded"}
  end

  ## Private functions

  defp record(record) do
    s3 = record["s3"] || %{}
    bucket = s3["bucket"] || %{}
    object = s3["object"] || %{}

    %Record{
      event_name: record["eventName"],
      event_time: Events.datetime(record["eventTime"]),
      region: record["awsRegion"],
      bucket: bucket["name"],
      bucket_arn: bucket["arn"],
      key: object["key"] && URI.decode_www_form(object["key"]),
      size: object["size"],
      etag: object["eTag"],
      version_id: object["versionId"],
      sequencer: object["sequencer"]
    }
  end
end
