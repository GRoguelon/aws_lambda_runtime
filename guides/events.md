# AWS service events

When SQS, SNS, S3, EventBridge, Kinesis or DynamoDB Streams invoke the
function, `handle/3` receives their event as a struct, with what AWS encodes
decoded:

| Source | Struct | Decoded |
|---|---|---|
| SQS | `AWS.Lambda.Runtime.Events.SQS` | message attributes |
| SNS | `AWS.Lambda.Runtime.Events.SNS` | message attributes, timestamp |
| S3 | `AWS.Lambda.Runtime.Events.S3` | the object key, which S3 sends URL-encoded |
| EventBridge | `AWS.Lambda.Runtime.Events.EventBridge` | the event's time |
| Kinesis | `AWS.Lambda.Runtime.Events.Kinesis` | the data, from base64 |
| DynamoDB Streams | `AWS.Lambda.Runtime.Events.DynamoDB` | keys and images into plain maps: `%{"name" => %{"S" => "Ada"}}` reads `%{"name" => "Ada"}` |

Timestamps are `DateTime`s, and each struct keeps the invocation's event in
`:event`. Message bodies, SQS's and SNS's, stay the strings they were sent
as: decode them as their sender encoded them.

```elixir
alias AWS.Lambda.Runtime.Events.{DynamoDB, EventBridge, S3, SQS}

def handle(%S3{records: records}, _context, _state) do
  for %S3.Record{event_name: "ObjectCreated:" <> _, bucket: bucket, key: key} <- records do
    index(bucket, key)
  end

  :ok
end

def handle(%EventBridge{source: "myapp.orders", detail_type: "OrderPlaced", detail: order}, _context, _state) do
  fulfil(order)
end

def handle(%DynamoDB{records: records}, _context, _state) do
  for %DynamoDB.Record{event_name: "INSERT", new_image: item} <- records, do: notify(item)
  :ok
end
```

An event from one of these sources that can't be decoded, such as Kinesis
data that isn't valid base64, is reported as a `Runtime.MalformedEvent`
error without calling the handler. Any other event reaches `handle/3` as the
payload decoded from JSON.

## Partial batch failures

SQS, Kinesis and DynamoDB Streams deliver records in batches. A handler
returning `{:error, reason}`, or raising, has the whole batch retried;
returning `{:retry, failed}`, with the records that failed or their IDs, has
only those retried:

```elixir
def handle(%SQS{records: messages}, _context, _state) do
  {:retry, Enum.reject(messages, &(process(&1) == :ok))}
end
```

The event source mapping must have `ReportBatchItemFailures` among its
function response types:

```sh
aws lambda update-event-source-mapping --uuid <mapping-uuid> \
  --function-response-types ReportBatchItemFailures
```

`{:retry, []}` reports the whole batch as processed.
