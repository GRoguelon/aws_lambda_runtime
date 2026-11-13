defmodule AWS.Lambda.Runtime.Request do
  @moduledoc """
  An HTTP request, as a Function URL or API Gateway sends it to the function.

  The runtime builds it from the invocation's event, so `c:AWS.Lambda.Runtime.Handler.handle/3`
  receives it ready to use, whichever sent it:

    * a Function URL, or an API Gateway HTTP API, in payload format 2.0;
    * an API Gateway REST API with a Lambda proxy integration, or an HTTP API
      set to payload format 1.0.

  ## Fields

    * `:method` - `"GET"`, `"POST"`…
    * `:path` - `"/users/42"`.
    * `:query` - the query string, decoded: `%{"fields" => "name"}`. A key
      given several times keeps its last value.
    * `:headers` - names lowercased. Values given several times are joined
      with `", "`.
    * `:cookies` - `%{"session" => "abc"}`.
    * `:body` - decoded from base64 when it was encoded, then according to
      its `content-type`: JSON (`application/json`, `*+json`) and forms
      (`application/x-www-form-urlencoded`) into maps, anything else left as
      a binary. `nil` without a body.
    * `:path_params` - the path parameters of an API Gateway route.
    * `:source_ip` - the client's IP address.
    * `:event` - the invocation's event, for anything else.
    * `:format` - the payload format, `:v2` or `:v1`, which sets the format
      of the response.

  A body that can't be decoded is answered with a `400` by the runtime,
  without calling the handler.
  """

  ## Types

  @type t :: %__MODULE__{
          method: String.t(),
          path: String.t(),
          query: %{String.t() => String.t()},
          headers: %{String.t() => String.t()},
          cookies: %{String.t() => String.t()},
          body: term(),
          path_params: %{String.t() => String.t()},
          source_ip: String.t() | nil,
          event: map(),
          format: :v1 | :v2
        }

  ## Module attributes

  defstruct method: nil,
            path: nil,
            query: %{},
            headers: %{},
            cookies: %{},
            body: nil,
            path_params: %{},
            source_ip: nil,
            event: %{},
            format: :v2

  ## Public functions

  @doc """
  Builds the request from an invocation's event.

  Returns `:error` when the event isn't an HTTP request, and
  `{:error, message}` when its body can't be decoded.
  """
  @spec from_event(term()) :: {:ok, t()} | {:error, String.t()} | :error
  def from_event(
        %{"version" => "2.0", "requestContext" => %{"http" => %{"method" => method}}} = event
      ) do
    http = event["requestContext"]["http"]
    headers = downcase_keys(event["headers"])

    build(event, headers, %__MODULE__{
      method: method,
      path: event["rawPath"] || http["path"],
      query: decode_query(event["rawQueryString"]),
      headers: headers,
      cookies: cookies(event["cookies"] || []),
      path_params: event["pathParameters"] || %{},
      source_ip: http["sourceIp"],
      event: event,
      format: :v2
    })
  end

  def from_event(%{"httpMethod" => method, "requestContext" => context} = event)
      when is_binary(method) and is_map(context) and not is_map_key(context, "elb") do
    headers = v1_headers(event)

    build(event, headers, %__MODULE__{
      method: method,
      path: event["path"],
      query: v1_query(event),
      headers: headers,
      cookies: headers |> Map.get("cookie", "") |> String.split(";") |> cookies(),
      path_params: event["pathParameters"] || %{},
      source_ip: get_in(context, ["identity", "sourceIp"]),
      event: event,
      format: :v1
    })
  end

  def from_event(_event) do
    :error
  end

  ## Private functions

  defp build(event, headers, request) do
    with {:ok, raw} <- raw_body(event),
         {:ok, body} <- decode_body(raw, headers["content-type"]) do
      {:ok, %{request | body: body}}
    end
  end

  # Body

  defp raw_body(%{"body" => body, "isBase64Encoded" => true}) when is_binary(body) do
    case Base.decode64(body) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, "the request body is not valid base64"}
    end
  end

  defp raw_body(%{"body" => body}) when is_binary(body) do
    {:ok, body}
  end

  defp raw_body(_event) do
    {:ok, nil}
  end

  defp decode_body(nil, _content_type) do
    {:ok, nil}
  end

  defp decode_body(raw, content_type) do
    case media_type(content_type) do
      :json when raw == "" ->
        {:ok, nil}

      :json ->
        case JSON.decode(raw) do
          {:ok, body} -> {:ok, body}
          {:error, _reason} -> {:error, "the request body is not valid JSON"}
        end

      :form ->
        try do
          {:ok, URI.decode_query(raw)}
        rescue
          ArgumentError -> {:error, "the request body is not a valid form"}
        end

      :other ->
        {:ok, raw}
    end
  end

  defp media_type(nil) do
    :other
  end

  defp media_type(content_type) do
    case content_type
         |> String.split(";", parts: 2)
         |> hd()
         |> String.trim()
         |> String.downcase() do
      "application/json" -> :json
      "application/x-www-form-urlencoded" -> :form
      type -> if String.ends_with?(type, "+json"), do: :json, else: :other
    end
  end

  # Query string, headers, cookies

  defp decode_query(query) when query in [nil, ""] do
    %{}
  end

  defp decode_query(query) do
    URI.decode_query(query)
  rescue
    ArgumentError -> %{}
  end

  # Values already decoded. A key given several times keeps its last value,
  # as with format 2.0.
  defp v1_query(%{"multiValueQueryStringParameters" => %{} = params}) do
    Map.new(params, fn {key, values} -> {key, List.last(List.wrap(values))} end)
  end

  defp v1_query(%{"queryStringParameters" => %{} = params}) do
    params
  end

  defp v1_query(_event) do
    %{}
  end

  defp v1_headers(%{"multiValueHeaders" => %{} = headers}) do
    Map.new(headers, fn {name, values} ->
      {String.downcase(name), values |> List.wrap() |> Enum.join(", ")}
    end)
  end

  defp v1_headers(event) do
    downcase_keys(event["headers"])
  end

  defp downcase_keys(nil) do
    %{}
  end

  defp downcase_keys(headers) do
    Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
  end

  defp cookies(pairs) do
    for pair <- pairs,
        [name, value] <- [pair |> String.trim() |> String.split("=", parts: 2)],
        name != "",
        into: %{},
        do: {name, value}
  end
end
