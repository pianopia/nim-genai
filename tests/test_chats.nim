import std/[asyncdispatch, asynchttpserver, json, nativesockets, unittest]

import ../src/nim_genai/[client, chats, types]

suite "Chats API":
  test "newChatSession validates inputs":
    let c = newClient(
      apiKey = "test-key",
      baseUrl = "http://127.0.0.1:1/",
      apiVersion = "v1beta"
    )
    defer: c.close()

    expect(ValueError):
      discard newChatSession(c, "")

  test "chat session sends history across turns":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestCount = 0
      var firstRequestHasSystemInstruction = false
      var secondRequestHasHistory = false

      proc cb(req: Request) {.async, gcsafe.} =
        inc(requestCount)
        let requestJson = parseJson(req.body)

        if requestCount == 1:
          try:
            firstRequestHasSystemInstruction = (
              requestJson["systemInstruction"]["parts"][0]["text"].getStr() == "You are helpful."
            )
          except CatchableError:
            firstRequestHasSystemInstruction = false
        elif requestCount == 2:
          try:
            secondRequestHasHistory = (
              requestJson["contents"].kind == JArray and
              requestJson["contents"].len == 3 and
              requestJson["contents"][0]["role"].getStr() == "user" and
              requestJson["contents"][0]["parts"][0]["text"].getStr() == "hello" and
              requestJson["contents"][1]["role"].getStr() == "model" and
              requestJson["contents"][1]["parts"][0]["text"].getStr() == "Hi there!" and
              requestJson["contents"][2]["role"].getStr() == "user" and
              requestJson["contents"][2]["parts"][0]["text"].getStr() == "how are you?"
            )
          except CatchableError:
            secondRequestHasHistory = false

        var responseJson: JsonNode
        if requestCount == 1:
          responseJson = %*{
            "candidates": [
              {"content": {"parts": [{"text": "Hi there!"}]}}
            ]
          }
        else:
          responseJson = %*{
            "candidates": [
              {"content": {"parts": [{"text": "Doing great."}]}}
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
      let chat = newChatSession(
        client = c,
        model = "gemini-2.5-flash",
        systemInstruction = "You are helpful."
      )

      let response1 = await chat.sendMessage("hello")
      let response2 = await chat.sendMessage("how are you?")

      c.close()
      server.close()

      check requestCount == 2
      check firstRequestHasSystemInstruction
      check secondRequestHasHistory
      check response1.text == "Hi there!"
      check response2.text == "Doing great."

      let history = chat.getHistory()
      check history.len == 4
      check history[0].role == "user"
      check history[1].role == "model"
      check history[2].role == "user"
      check history[3].role == "model"
      check history[3].parts[0].text == "Doing great."

      chat.clearHistory()
      check chat.getHistory().len == 0

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()
