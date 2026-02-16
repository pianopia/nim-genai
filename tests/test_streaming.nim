import std/[asyncdispatch, asynchttpserver, json, nativesockets, unittest]

import ../src/nim_genai/client
import ../src/nim_genai/streaming

suite "SSE streaming parser":
  test "parses data lines split across chunks":
    var parser: SseLineParser
    let first = parser.consumeSseChunk(
      "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"He"
    )
    check first.len == 0

    let second = parser.consumeSseChunk("llo\"}]}}]}\n\n")
    check second.len == 1

    let payload = parseJson(second[0])
    check payload["candidates"][0]["content"]["parts"][0]["text"].getStr() == "Hello"

  test "parses line-by-line JSON errors without data prefix":
    var parser: SseLineParser
    check parser.consumeSseChunk("{\"error\":{\n").len == 0
    check parser.consumeSseChunk("\"code\":400,\n").len == 0

    let payloads = parser.consumeSseChunk("\"message\":\"bad\"}}\n")
    check payloads.len == 1
    check parseJson(payloads[0])["error"]["code"].getInt() == 400

  test "flushes trailing payload without a trailing newline":
    var parser: SseLineParser
    check parser.consumeSseChunk("data: {\"a\":1}").len == 0

    let payloads = parser.flushSseChunkParser()
    check payloads.len == 1
    check parseJson(payloads[0])["a"].getInt() == 1

  test "supports CRLF line endings":
    var parser: SseLineParser
    let payloads = parser.consumeSseChunk("data: {\"a\":1}\r\n\r\n")
    check payloads.len == 1
    check parseJson(payloads[0])["a"].getInt() == 1

  test "returns DONE sentinel payload":
    var parser: SseLineParser
    let payloads = parser.consumeSseChunk("data: [DONE]\n\n")
    check payloads.len == 1
    check payloads[0] == "[DONE]"

  test "stream API returns chunked text from SSE endpoint":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      proc cb(req: Request) {.async, gcsafe.} =
        let body =
          "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello \"}]}}]}\n\n" &
          "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"world\"}]}}]}\n\n" &
          "data: [DONE]\n\n"
        var headers = newHttpHeaders()
        headers["Content-Type"] = "text/event-stream"
        await req.respond(Http200, body, headers)

      asyncCheck server.acceptRequest(cb)

      let client = newClient(
        apiKey = "test-key",
        baseUrl = "http://127.0.0.1:" & $port & "/",
        apiVersion = "v1beta"
      )

      let stream = client.generateContentStream(
        model = "gemini-2.5-flash",
        prompt = "hello"
      )

      var chunks: seq[string] = @[]
      while true:
        let (hasChunk, chunk) = await stream.read()
        if not hasChunk:
          break
        chunks.add(chunk.text)

      client.close()
      server.close()

      check chunks == @["Hello ", "world"]

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()
