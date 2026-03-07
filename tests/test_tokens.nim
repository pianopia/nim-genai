import std/[asyncdispatch, asynchttpserver, json, nativesockets, options, strutils, unittest]

import ../src/nim_genai/[client, types]

suite "Tokens API":
  test "extract countTokens response":
    let raw = %*{
      "totalTokens": 15,
      "cachedContentTokenCount": 3
    }
    let response = extractCountTokensResponse(raw)
    check response.totalTokens.isSome and response.totalTokens.get() == 15
    check response.cachedContentTokenCount.isSome and response.cachedContentTokenCount.get() == 3

  test "countTokens sends request and parses response":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestPath = ""
      var requestMethod = ""
      var requestValidated = false

      proc cb(req: Request) {.async, gcsafe.} =
        requestPath = req.url.path
        requestMethod = $req.reqMethod

        let requestJson = parseJson(req.body)
        try:
          requestValidated = (
            requestJson.kind == JObject and
            requestJson["contents"].kind == JArray and
            requestJson["contents"].len == 2 and
            requestJson["contents"][0]["parts"][0]["text"].getStr() == "hello" and
            requestJson["contents"][1]["parts"][0]["text"].getStr() == "world"
          )
        except CatchableError:
          requestValidated = false

        let responseJson = %*{
          "totalTokens": 7,
          "cachedContentTokenCount": 1
        }
        var headers = newHttpHeaders()
        headers["Content-Type"] = "application/json"
        await req.respond(Http200, $responseJson, headers)

      asyncCheck server.acceptRequest(cb)

      let c = newClient(
        apiKey = "test-key",
        baseUrl = "http://127.0.0.1:" & $port & "/",
        apiVersion = "v1beta"
      )
      let response = await c.countTokens(
        model = "gemini-2.5-flash",
        texts = @["hello", "world"]
      )

      c.close()
      server.close()

      check requestMethod == "HttpPost"
      check requestPath.endsWith("/v1beta/models/gemini-2.5-flash:countTokens")
      check requestValidated
      check response.totalTokens.isSome and response.totalTokens.get() == 7
      check response.cachedContentTokenCount.isSome and response.cachedContentTokenCount.get() == 1

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "countTokens rejects unsupported config fields for Gemini API":
    proc runInvalidConfig() {.async.} =
      let c = newClient(
        apiKey = "test-key",
        baseUrl = "http://127.0.0.1:1/",
        apiVersion = "v1beta"
      )
      defer: c.close()

      discard await c.countTokens(
        model = "gemini-2.5-flash",
        text = "hello",
        config = countTokensConfig(
          systemInstruction = some(contentFromText("You are strict."))
        )
      )

    expect(ValueError):
      waitFor runInvalidConfig()
