import std/[asyncdispatch, asynchttpserver, json, nativesockets, options, unittest]

import ../src/nim_genai/[client, types]

suite "Automatic function calling":
  test "generateContentAfc executes handler and continues with tool response":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestCount = 0
      var secondRequestHasFunctionResponse = false

      proc cb(req: Request) {.async, gcsafe.} =
        inc(requestCount)
        let requestJson = parseJson(req.body)
        if requestCount == 2:
          try:
            let functionResponse =
              requestJson["contents"][2]["parts"][0]["functionResponse"]["response"]["result"]
            secondRequestHasFunctionResponse = functionResponse["city"].getStr() == "Tokyo"
          except CatchableError:
            secondRequestHasFunctionResponse = false

        var responseJson: JsonNode
        if requestCount == 1:
          responseJson = %*{
            "candidates": [
              {
                "content": {
                  "parts": [
                    {
                      "functionCall": {
                        "name": "getWeather",
                        "args": {"city": "Tokyo"}
                      }
                    }
                  ]
                }
              }
            ]
          }
        else:
          responseJson = %*{
            "candidates": [
              {
                "content": {
                  "parts": [
                    {"text": "Tokyo is 21C"}
                  ]
                }
              }
            ]
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

      var handlers = newFunctionHandlerMap()
      handlers.setFunctionHandler(
        "getWeather",
        proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
          result = %*{
            "city": args["city"].getStr(),
            "temperature": 21
          }
      )

      let decl = functionDeclaration(
        "getWeather",
        "Returns weather by city.",
        %*{
          "type": "object",
          "properties": {
            "city": {"type": "string"}
          },
          "required": ["city"]
        }
      )
      let config = GenerateContentConfig(
        tools: @[toolFromFunctions(@[decl])],
        automaticFunctionCalling: some(automaticFunctionCallingConfig(
          disable = some(false),
          maximumRemoteCalls = some(2),
          ignoreCallHistory = some(false)
        ))
      )

      let response = await c.generateContentAfc(
        model = "gemini-2.5-flash",
        prompt = "What's the weather in Tokyo?",
        functionHandlers = handlers,
        config = config
      )

      c.close()
      server.close()

      check response.text == "Tokyo is 21C"
      check requestCount == 2
      check secondRequestHasFunctionResponse
      check response.automaticFunctionCallingHistory.len >= 3

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()
