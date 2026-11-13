# Streaming responses

A handler can stream its response instead of returning it all at once, by
returning `{:stream, chunks}` or `{:stream, chunks, opts}`, where `chunks` is
any enumerable of iodata, such as a `Stream`. Each element is sent as soon as
it is produced.

Lambda only streams to callers that ask for it: a Function URL in
`RESPONSE_STREAM` mode, or the `InvokeWithResponseStream` API. Other callers,
the Lambda console included, receive the whole response once it is complete,
and API Gateway doesn't stream Lambda responses.

See the `AWS.Lambda.Runtime.Handler` moduledoc for every option, and for how
an error is reported once streaming has started.

The two examples below extend the `HelloFunction` handler of
[Getting started](getting-started.md#3-write-a-handler). Add their `handle/3`
clauses above its last one, which matches any event and so must come last. Both stream a line every half second, from this
helper:

```elixir
defp chunks(count) do
  Stream.map(1..count, fn i ->
    Process.sleep(500)
    "chunk #{i} of #{count}\n"
  end)
end
```

The whole stream must be sent before the function's timeout, 3 seconds by
default: raise it for longer streams.

```sh
aws lambda update-function-configuration --function-name elixir-hello --timeout 15
```

## Example: streaming in reply to an event

Invoked through the `InvokeWithResponseStream` API, the handler receives the
payload as its event, like any invocation, and its chunks are sent as they
are:

```elixir
def handle(%{"stream" => count}, _context, _state) when is_integer(count) do
  {:stream, chunks(count), content_type: "text/plain"}
end
```

The AWS CLI doesn't offer `InvokeWithResponseStream`; call it from an AWS
SDK instead, e.g. with Python and boto3, printing each chunk as it arrives:

```python
import json

import boto3

response = boto3.client("lambda").invoke_with_response_stream(
    FunctionName="elixir-hello", Payload=json.dumps({"stream": 4})
)

for event in response["EventStream"]:
    if "PayloadChunk" in event:
        print(event["PayloadChunk"]["Payload"].decode(), end="", flush=True)
    elif error := event.get("InvokeComplete", {}).get("ErrorCode"):
        print(f"\nerror: {error}: {event['InvokeComplete'].get('ErrorDetails')}")
```

An error raised once streaming has started arrives in the final
`InvokeComplete` event, after the chunks sent before it.

## Example: streaming through a Function URL

A Function URL hands the handler an `AWS.Lambda.Runtime.Request`, and the
runtime sends the status, headers and cookies of the HTTP response before its
body (status `200` unless given):

```elixir
def handle(%Request{query: %{"stream" => count}}, _context, _state) do
  {:stream, chunks(String.to_integer(count)),
   content_type: "text/plain", headers: %{"cache-control" => "no-cache"}}
end
```

Create a URL in `RESPONSE_STREAM` mode, tell the runtime so (see [Function URL invoke
mode](http.md#function-url-invoke-mode)),
allow it to be called, and call it with `curl -N`, which prints each chunk as
it arrives:

```sh
aws lambda create-function-url-config --function-name elixir-hello \
  --auth-type NONE --invoke-mode RESPONSE_STREAM --query FunctionUrl --output text
aws lambda update-function-configuration --function-name elixir-hello \
  --environment '{"Variables": {"FUNCTION_URL_INVOKE_MODE": "RESPONSE_STREAM"}}'
aws lambda add-permission --function-name elixir-hello \
  --statement-id FunctionURLAllowPublicAccess --action lambda:InvokeFunctionUrl \
  --principal "*" --function-url-auth-type NONE
aws lambda add-permission --function-name elixir-hello \
  --statement-id FunctionURLInvokeFunction --action lambda:InvokeFunction \
  --principal "*" --invoked-via-function-url

curl -iN "https://<url-id>.lambda-url.<region>.on.aws/?stream=4"
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Transfer-Encoding: chunked
cache-control: no-cache
...

chunk 1 of 4
chunk 2 of 4
chunk 3 of 4
chunk 4 of 4
```

`NONE` makes the URL public: anyone with it can invoke the function. It
needs both permissions, and `--invoked-via-function-url` limits the second
one to calls made through the URL; without them, the URL answers `403
Forbidden`. See the Lambda documentation on Function URLs for `AWS_IAM`
authentication instead. Remove the URL and its permissions once done:

```sh
aws lambda delete-function-url-config --function-name elixir-hello
aws lambda remove-permission --function-name elixir-hello \
  --statement-id FunctionURLAllowPublicAccess
aws lambda remove-permission --function-name elixir-hello \
  --statement-id FunctionURLInvokeFunction
```
