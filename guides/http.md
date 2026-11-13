# HTTP requests

A Function URL, or API Gateway with a Lambda proxy integration, invokes the
function with an event describing an HTTP request. `handle/3` receives it as
an `AWS.Lambda.Runtime.Request`, decoded and ready to use, whichever sent it:

- a Function URL, or an API Gateway HTTP API, in payload format 2.0;
- an API Gateway REST API, or an HTTP API set to payload format 1.0.

```elixir
alias AWS.Lambda.Runtime.Request

def handle(%Request{method: "GET", path: "/users/" <> id, query: query}, _context, state) do
  {:ok, Users.get(state.repo, id, query["fields"])}
end

def handle(%Request{method: "POST", path: "/users", body: %{"name" => name}}, _context, state) do
  {:ok, Users.create(state.repo, name), status: 201}
end
```

## The request

| Field | Content |
|---|---|
| `method` | `"GET"`, `"POST"`… |
| `path` | `"/users/42"` |
| `query` | the query string, decoded: `%{"fields" => "name"}`; a key given several times keeps its last value |
| `headers` | names lowercased; values given several times joined with `", "` |
| `cookies` | `%{"session" => "abc"}` |
| `body` | decoded from base64 when it was, then by its `content-type`: JSON and forms into maps, anything else left as a binary; `nil` without a body |
| `path_params` | the path parameters of an API Gateway route |
| `source_ip` | the client's IP address |
| `source` | `:function_url` or `:api_gateway` |
| `event` | the invocation's event, for anything else |

A body that can't be decoded, say malformed JSON, is answered with a `400`
without calling the handler, so a clause matching `body: %{…}` never sees
one.

## The response

`{:ok, body}` answers with status `200` and `body` encoded in JSON.
`{:ok, body, opts}` takes:

- `:status`, `:headers` (a map) and `:cookies` (a list of `Set-Cookie`
  values);
- `:content_type`, which returns a binary `body` as is rather than in JSON.

```elixir
def handle(%Request{path: "/robots.txt"}, _context, _state) do
  {:ok, "User-agent: *\nDisallow: /\n",
   content_type: "text/plain", headers: %{"cache-control" => "max-age=3600"}}
end
```

The runtime encodes the response as the Function URL or API Gateway expects
it, in the request's payload format: a body that isn't valid UTF-8 is sent in
base64, and header names are lowercased. When no `handle/3` clause matches a
request, the runtime answers it with a `404`. `{:stream, chunks, opts}`
takes the same options, see [Streaming responses](streaming.md).

An Application Load Balancer's events, and an API Gateway WebSocket API's,
aren't HTTP requests the runtime decodes: `handle/3` receives them as they
are.

## Function URL invoke mode

Lambda reads a Function URL's response differently in each of its invoke
modes, without telling the function which one the URL uses: in
`RESPONSE_STREAM` mode it only reads a stream, in `BUFFERED` mode, the
default, only a response sent at once. The runtime sends either, whatever the
handler returns, once it knows the URL's mode, which it takes from, by
priority:

1. the function's `FUNCTION_URL_INVOKE_MODE` environment variable,
   `RESPONSE_STREAM` or `BUFFERED`, so the mode can follow the URL's without
   a new deployment (`--environment` replaces all the function's variables,
   so include the existing ones);
2. `config :aws_lambda_runtime, function_url: :response_stream` (or
   `:buffered`);
3. `BUFFERED`, the URL's default.

In `BUFFERED` mode, and for API Gateway, a `{:stream, …}` response is sent
once complete; with the wrong mode, the caller gets an empty body or the
response's envelope instead of its body.

To change a URL's mode, change the variable along with it. Lambda takes a few
minutes to apply the new mode everywhere: until then, some responses come
back with an empty body, whatever the function sends.
