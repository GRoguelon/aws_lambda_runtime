defmodule AWS.Lambda.Runtime.EventsTest do
  use ExUnit.Case, async: true

  alias AWS.Lambda.Runtime.Events
  alias AWS.Lambda.Runtime.Events.DynamoDB
  alias AWS.Lambda.Runtime.Events.EventBridge
  alias AWS.Lambda.Runtime.Events.Kinesis
  alias AWS.Lambda.Runtime.Events.S3
  alias AWS.Lambda.Runtime.Events.SNS
  alias AWS.Lambda.Runtime.Events.SQS

  @sqs %{
    "Records" => [
      %{
        "messageId" => "059f36b4-87a3-44ab-83d2-661975830a7d",
        "receiptHandle" => "AQEBwJnKyrHigUMZj6rYigCgxlaS3SLy0a",
        "body" => ~s({"order":42}),
        "attributes" => %{"ApproximateReceiveCount" => "1"},
        "messageAttributes" => %{
          "tenant" => %{"stringValue" => "acme", "dataType" => "String"},
          "blob" => %{"binaryValue" => Base.encode64(<<1, 2>>), "dataType" => "Binary"}
        },
        "md5OfBody" => "e4e68fb7bd0e697a0ae8f1bb342846b3",
        "eventSource" => "aws:sqs",
        "eventSourceARN" => "arn:aws:sqs:eu-west-3:123456789012:orders",
        "awsRegion" => "eu-west-3"
      }
    ]
  }

  @sns %{
    "Records" => [
      %{
        "EventSource" => "aws:sns",
        "EventSubscriptionArn" => "arn:aws:sns:eu-west-3:123456789012:alerts:2bcfbf39",
        "Sns" => %{
          "Type" => "Notification",
          "MessageId" => "95df01b4-ee98-5cb9-9903-4c221d41eb5e",
          "TopicArn" => "arn:aws:sns:eu-west-3:123456789012:alerts",
          "Subject" => "disk",
          "Message" => "disk almost full",
          "Timestamp" => "2026-11-13T12:00:00.000Z",
          "MessageAttributes" => %{"severity" => %{"Type" => "String", "Value" => "high"}}
        }
      }
    ]
  }

  @s3 %{
    "Records" => [
      %{
        "eventSource" => "aws:s3",
        "eventName" => "ObjectCreated:Put",
        "eventTime" => "2026-11-13T12:00:00.000Z",
        "awsRegion" => "eu-west-3",
        "s3" => %{
          "bucket" => %{"name" => "uploads", "arn" => "arn:aws:s3:::uploads"},
          "object" => %{
            "key" => "reports/2026+Q4%2Fsummary.pdf",
            "size" => 1024,
            "eTag" => "0123456789abcdef",
            "sequencer" => "0A1B2C3D4E5F678901"
          }
        }
      }
    ]
  }

  @event_bridge %{
    "version" => "0",
    "id" => "6a7e8feb-b491-4cf7-a9f1-bf3703467718",
    "detail-type" => "OrderPlaced",
    "source" => "myapp.orders",
    "account" => "123456789012",
    "time" => "2026-11-13T12:00:00Z",
    "region" => "eu-west-3",
    "resources" => ["arn:aws:events:eu-west-3:123456789012:rule/orders"],
    "detail" => %{"order" => 42}
  }

  @kinesis %{
    "Records" => [
      %{
        "kinesis" => %{
          "kinesisSchemaVersion" => "1.0",
          "partitionKey" => "1",
          "sequenceNumber" => "49590338271490256608559692538361571095921575989136588898",
          "data" => Base.encode64("Hello, this is a test."),
          "approximateArrivalTimestamp" => 1_794_571_200.5
        },
        "eventSource" => "aws:kinesis",
        "eventID" => "shardId-000000000006:4959033827149025660855969253",
        "eventSourceARN" => "arn:aws:kinesis:eu-west-3:123456789012:stream/clicks",
        "awsRegion" => "eu-west-3"
      }
    ]
  }

  @dynamodb %{
    "Records" => [
      %{
        "eventID" => "c4ca4238a0b923820dcc509a6f75849b",
        "eventName" => "MODIFY",
        "eventSource" => "aws:dynamodb",
        "eventSourceARN" => "arn:aws:dynamodb:eu-west-3:123456789012:table/users/stream/x",
        "awsRegion" => "eu-west-3",
        "dynamodb" => %{
          "Keys" => %{"id" => %{"N" => "101"}},
          "NewImage" => %{
            "id" => %{"N" => "101"},
            "name" => %{"S" => "Ada"},
            "score" => %{"N" => "4.5"},
            "admin" => %{"BOOL" => true},
            "avatar" => %{"B" => Base.encode64(<<255>>)},
            "nickname" => %{"NULL" => true},
            "tags" => %{"SS" => ["a", "b"]},
            "lucky" => %{"NS" => ["7", "13"]},
            "address" => %{"M" => %{"city" => %{"S" => "Paris"}}},
            "history" => %{"L" => [%{"N" => "1"}, %{"S" => "two"}]}
          },
          "OldImage" => %{"id" => %{"N" => "101"}, "name" => %{"S" => "Ada L."}},
          "SequenceNumber" => "222",
          "ApproximateCreationDateTime" => 1_794_571_200,
          "StreamViewType" => "NEW_AND_OLD_IMAGES"
        }
      }
    ]
  }

  describe "decode/1" do
    test "decodes an SQS event" do
      assert {:ok, %SQS{records: [message], event: @sqs}} = Events.decode(@sqs)

      assert %SQS.Message{
               message_id: "059f36b4-87a3-44ab-83d2-661975830a7d",
               body: ~s({"order":42}),
               attributes: %{"ApproximateReceiveCount" => "1"},
               message_attributes: %{"tenant" => "acme", "blob" => <<1, 2>>},
               region: "eu-west-3"
             } = message
    end

    test "decodes an SNS event" do
      assert {:ok, %SNS{records: [message]}} = Events.decode(@sns)

      assert %SNS.Message{
               subject: "disk",
               message: "disk almost full",
               topic_arn: "arn:aws:sns:eu-west-3:123456789012:alerts",
               message_attributes: %{"severity" => "high"},
               timestamp: ~U[2026-11-13 12:00:00.000Z]
             } = message
    end

    test "decodes an S3 event, its key URL-decoded" do
      assert {:ok, %S3{records: [record]}} = Events.decode(@s3)

      assert %S3.Record{
               event_name: "ObjectCreated:Put",
               bucket: "uploads",
               key: "reports/2026 Q4/summary.pdf",
               size: 1024,
               event_time: ~U[2026-11-13 12:00:00.000Z]
             } = record
    end

    test "decodes an EventBridge event" do
      assert {:ok,
              %EventBridge{
                source: "myapp.orders",
                detail_type: "OrderPlaced",
                detail: %{"order" => 42},
                time: ~U[2026-11-13 12:00:00Z],
                resources: ["arn:aws:events:eu-west-3:123456789012:rule/orders"]
              }} = Events.decode(@event_bridge)
    end

    test "decodes a Kinesis event, its data from base64" do
      assert {:ok, %Kinesis{records: [record]}} = Events.decode(@kinesis)

      assert %Kinesis.Record{
               data: "Hello, this is a test.",
               partition_key: "1",
               sequence_number: "49590338271490256608559692538361571095921575989136588898"
             } = record

      assert record.arrival_time == DateTime.from_unix!(1_794_571_200_500, :millisecond)
    end

    test "reports Kinesis data that isn't base64" do
      event = put_in(@kinesis, ["Records", Access.at(0), "kinesis", "data"], "%%%")

      assert {:error, "the data of Kinesis record 4959" <> _rest} = Events.decode(event)

      event =
        update_in(event, ["Records", Access.at(0), "kinesis"], &Map.delete(&1, "sequenceNumber"))

      assert Events.decode(event) == {:error, "the data of a Kinesis record is not valid base64"}
    end

    test "decodes a DynamoDB Streams event into plain maps" do
      assert {:ok, %DynamoDB{records: [record]}} = Events.decode(@dynamodb)

      assert record.event_name == "MODIFY"
      assert record.keys == %{"id" => 101}
      assert record.sequence_number == "222"
      assert record.old_image == %{"id" => 101, "name" => "Ada L."}

      assert record.new_image == %{
               "id" => 101,
               "name" => "Ada",
               "score" => 4.5,
               "admin" => true,
               "avatar" => <<255>>,
               "nickname" => nil,
               "tags" => ["a", "b"],
               "lucky" => [7, 13],
               "address" => %{"city" => "Paris"},
               "history" => [1, "two"]
             }
    end

    test "reports a DynamoDB value it can't decode" do
      event =
        put_in(@dynamodb, ["Records", Access.at(0), "dynamodb", "Keys"], %{"id" => %{"N" => "x"}})

      assert Events.decode(event) ==
               {:error, "a DynamoDB stream record holds a value that can't be decoded"}
    end

    test "leaves any other event alone" do
      assert Events.decode(%{"name" => "Ada"}) == :error
      assert Events.decode(%{"Records" => []}) == :error
      assert Events.decode(%{"Records" => [%{"eventSource" => "aws:unknown"}]}) == :error
      assert Events.decode("text") == :error
    end
  end

  describe "batch_item_failures/1" do
    test "identifies records by their source's ID, and takes IDs as they are" do
      {:ok, %SQS{records: [message]}} = Events.decode(@sqs)
      {:ok, %Kinesis{records: [kinesis]}} = Events.decode(@kinesis)
      {:ok, %DynamoDB{records: [change]}} = Events.decode(@dynamodb)

      assert Events.batch_item_failures([message, kinesis, change, "raw-id"]) ==
               {:ok,
                %{
                  "batchItemFailures" => [
                    %{"itemIdentifier" => "059f36b4-87a3-44ab-83d2-661975830a7d"},
                    %{
                      "itemIdentifier" =>
                        "49590338271490256608559692538361571095921575989136588898"
                    },
                    %{"itemIdentifier" => "222"},
                    %{"itemIdentifier" => "raw-id"}
                  ]
                }}

      assert Events.batch_item_failures([]) == {:ok, %{"batchItemFailures" => []}}
    end

    test "refuses what it can't identify" do
      assert {:error, "cannot retry 42: " <> _rest} = Events.batch_item_failures([42])
      assert {:error, "{:retry, failed} takes a list" <> _rest} = Events.batch_item_failures(:all)
    end
  end
end
