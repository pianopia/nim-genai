import std/[asyncdispatch, asynchttpserver, json, nativesockets, options, strutils, unittest]

import ../src/nim_genai/[client, types]

suite "Embeddings":
  test "embed content config serializes":
    let cfg = embedContentConfig(
      taskType = some("RETRIEVAL_DOCUMENT"),
      title = some("doc-title"),
      outputDimensionality = some(8)
    )
    let j = cfg.toJson()
    check j["taskType"].getStr() == "RETRIEVAL_DOCUMENT"
    check j["title"].getStr() == "doc-title"
    check j["outputDimensionality"].getInt() == 8

  test "extract embeddings and metadata":
    let raw = %*{
      "embeddings": [
        {
          "values": [0.1, 0.2]
        },
        {
          "values": [1.0],
          "statistics": {
            "tokenCount": 5,
            "truncated": false
          }
        }
      ],
      "metadata": {
        "billableCharacterCount": 42
      }
    }

    let embeddings = extractEmbeddings(raw)
    check embeddings.len == 2
    check abs(embeddings[0].values[0] - 0.1) < 0.000001
    check abs(embeddings[0].values[1] - 0.2) < 0.000001
    check embeddings[1].statistics.isSome
    check embeddings[1].statistics.get().truncated.get() == false
    check abs(embeddings[1].statistics.get().tokenCount.get() - 5.0) < 0.000001

    let metadata = extractEmbedContentMetadata(raw)
    check metadata.isSome
    check metadata.get().billableCharacterCount.get() == 42

  test "embedContent sends batchEmbedContents request and parses response":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestPath = ""
      var requestCount = 0
      var requestValidated = false

      proc cb(req: Request) {.async, gcsafe.} =
        inc(requestCount)
        requestPath = req.url.path

        let requestJson = parseJson(req.body)
        try:
          let requests = requestJson["requests"]
          requestValidated = (
            requests.kind == JArray and
            requests.len == 2 and
            requests[0]["model"].getStr() == "models/text-embedding-004" and
            requests[0]["content"]["parts"][0]["text"].getStr() == "hello" and
            requests[1]["content"]["parts"][0]["text"].getStr() == "world" and
            requests[0]["taskType"].getStr() == "RETRIEVAL_DOCUMENT" and
            requests[0]["title"].getStr() == "doc-title" and
            requests[0]["outputDimensionality"].getInt() == 3
          )
        except CatchableError:
          requestValidated = false

        let responseJson = %*{
          "embeddings": [
            {"values": [0.1, 0.2, 0.3]},
            {"values": [0.4, 0.5, 0.6]}
          ],
          "metadata": {
            "billableCharacterCount": 15
          }
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
      let response = await c.embedContent(
        model = "text-embedding-004",
        texts = @["hello", "world"],
        config = embedContentConfig(
          taskType = some("RETRIEVAL_DOCUMENT"),
          title = some("doc-title"),
          outputDimensionality = some(3)
        )
      )

      c.close()
      server.close()

      check requestCount == 1
      check requestPath.endsWith("/v1beta/models/text-embedding-004:batchEmbedContents")
      check requestValidated
      check response.embeddings.len == 2
      check response.embeddings[0].values.len == 3
      check abs(response.embeddings[1].values[2] - 0.6) < 0.000001
      check response.metadata.isSome
      check response.metadata.get().billableCharacterCount.get() == 15

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()
