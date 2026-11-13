defmodule AWS.Lambda.Runtime.RequestTest do
  use ExUnit.Case, async: true

  alias AWS.Lambda.Runtime.Request

  @v2 %{
    "version" => "2.0",
    "rawPath" => "/users/42",
    "rawQueryString" => "fields=name&tag=a&tag=b&q=hello%20world",
    "cookies" => ["session=abc", "theme=dark"],
    "headers" => %{"Content-Type" => "application/json", "x-forwarded-for" => "203.0.113.7"},
    "pathParameters" => %{"id" => "42"},
    "requestContext" => %{
      "domainName" => "abc.lambda-url.eu-west-3.on.aws",
      "http" => %{"method" => "POST", "path" => "/users/42", "sourceIp" => "203.0.113.7"}
    },
    "body" => ~s({"name":"Ada"}),
    "isBase64Encoded" => false
  }

  @v1 %{
    "resource" => "/users/{id}",
    "path" => "/users/42",
    "httpMethod" => "PUT",
    "multiValueHeaders" => %{
      "Content-Type" => ["application/x-www-form-urlencoded"],
      "Cookie" => ["session=abc; theme=dark"],
      "Accept" => ["text/html", "application/json"]
    },
    "multiValueQueryStringParameters" => %{"tag" => ["a", "b"], "fields" => ["name"]},
    "pathParameters" => %{"id" => "42"},
    "requestContext" => %{"identity" => %{"sourceIp" => "198.51.100.1"}},
    "body" => "name=Ada&role=admin",
    "isBase64Encoded" => false
  }

  describe "from_event/1 with payload format 2.0" do
    test "decodes the request" do
      assert {:ok, request} = Request.from_event(@v2)

      assert %Request{
               method: "POST",
               path: "/users/42",
               query: %{"fields" => "name", "tag" => "b", "q" => "hello world"},
               cookies: %{"session" => "abc", "theme" => "dark"},
               body: %{"name" => "Ada"},
               path_params: %{"id" => "42"},
               source_ip: "203.0.113.7",
               format: :v2
             } = request

      assert request.headers["content-type"] == "application/json"
      assert request.event == @v2
    end

    test "decodes a base64 encoded body" do
      event = %{@v2 | "body" => Base.encode64(~s({"name":"Ada"})), "isBase64Encoded" => true}

      assert {:ok, %Request{body: %{"name" => "Ada"}}} = Request.from_event(event)
    end

    test "keeps a body of another type as a binary" do
      event = put_in(@v2, ["headers", "Content-Type"], "image/png")
      event = %{event | "body" => Base.encode64(<<137, 80, 78, 71>>), "isBase64Encoded" => true}

      assert {:ok, %Request{body: <<137, 80, 78, 71>>}} = Request.from_event(event)
    end

    test "decodes a *+json body" do
      event = put_in(@v2, ["headers", "Content-Type"], "application/vnd.api+json; charset=utf-8")

      assert {:ok, %Request{body: %{"name" => "Ada"}}} = Request.from_event(event)
    end

    test "takes a missing or empty body as nil" do
      assert {:ok, %Request{body: nil}} = Request.from_event(Map.delete(@v2, "body"))
      assert {:ok, %Request{body: nil}} = Request.from_event(%{@v2 | "body" => ""})
    end

    test "reports a body that can't be decoded" do
      assert Request.from_event(%{@v2 | "body" => "{nope"}) ==
               {:error, "the request body is not valid JSON"}

      assert Request.from_event(%{@v2 | "body" => "%%%", "isBase64Encoded" => true}) ==
               {:error, "the request body is not valid base64"}
    end

    test "defaults what the event lacks" do
      event = %{
        "version" => "2.0",
        "requestContext" => %{"http" => %{"method" => "GET", "path" => "/"}}
      }

      assert {:ok,
              %Request{
                path: "/",
                query: %{},
                headers: %{},
                cookies: %{},
                path_params: %{},
                body: nil
              }} =
               Request.from_event(event)
    end
  end

  describe "from_event/1 sources" do
    test "tells a Function URL from API Gateway by its domain" do
      assert {:ok, %Request{source: :function_url}} = Request.from_event(@v2)

      api =
        put_in(@v2, ["requestContext", "domainName"], "abc.execute-api.eu-west-3.amazonaws.com")

      assert {:ok, %Request{source: :api_gateway}} = Request.from_event(api)

      assert {:ok, %Request{source: :api_gateway}} = Request.from_event(@v1)
    end
  end

  describe "from_event/1 with payload format 1.0" do
    test "decodes the request" do
      assert {:ok, request} = Request.from_event(@v1)

      assert %Request{
               method: "PUT",
               path: "/users/42",
               query: %{"tag" => "b", "fields" => "name"},
               cookies: %{"session" => "abc", "theme" => "dark"},
               body: %{"name" => "Ada", "role" => "admin"},
               path_params: %{"id" => "42"},
               source_ip: "198.51.100.1",
               format: :v1
             } = request

      assert request.headers["accept"] == "text/html, application/json"
    end

    test "falls back to the single-value headers and query string" do
      event =
        @v1
        |> Map.drop(["multiValueHeaders", "multiValueQueryStringParameters"])
        |> Map.merge(%{
          "headers" => %{"Content-Type" => "text/plain"},
          "queryStringParameters" => %{"fields" => "name"}
        })

      assert {:ok, %Request{query: %{"fields" => "name"}, body: "name=Ada&role=admin"}} =
               Request.from_event(event)
    end
  end

  describe "from_event/1 with other events" do
    test "returns :error" do
      assert Request.from_event(%{"name" => "Ada"}) == :error
      assert Request.from_event(%{"Records" => [%{"eventSource" => "aws:sqs"}]}) == :error
      assert Request.from_event([1, 2]) == :error
      assert Request.from_event(nil) == :error

      # An ALB's events are left as they are.
      assert Request.from_event(%{"httpMethod" => "GET", "requestContext" => %{"elb" => %{}}}) ==
               :error
    end
  end
end
