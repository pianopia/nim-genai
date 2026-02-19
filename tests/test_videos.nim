import std/[asyncdispatch, asynchttpserver, json, nativesockets, options, strutils, unittest]

import ../src/nim_genai/[client, types]

suite "Video APIs (Veo)":
  test "video helpers and config serialization":
    let uriVideo = videoFromUri("gs://bucket/input.mp4", some("video/mp4"))
    let uriVideoJson = uriVideo.toJson()
    check uriVideoJson["uri"].getStr() == "gs://bucket/input.mp4"
    check uriVideoJson["encoding"].getStr() == "video/mp4"

    let bytesVideo = videoFromBytes([1'u8, 2'u8, 3'u8], "video/mp4")
    let bytesVideoJson = bytesVideo.toJson()
    check bytesVideoJson["encodedVideo"].getStr() == "AQID"
    check bytesVideoJson["encoding"].getStr() == "video/mp4"

    let cfg = generateVideosConfig(
      numberOfVideos = some(2),
      durationSeconds = some(6),
      aspectRatio = some("16:9"),
      resolution = some("720p"),
      personGeneration = some("ALLOW_ADULT"),
      negativePrompt = some("low quality"),
      enhancePrompt = some(true)
    )
    let params = cfg.toJson()
    check params["sampleCount"].getInt() == 2
    check params["durationSeconds"].getInt() == 6
    check params["aspectRatio"].getStr() == "16:9"
    check params["resolution"].getStr() == "720p"
    check params["personGeneration"].getStr() == "ALLOW_ADULT"
    check params["negativePrompt"].getStr() == "low quality"
    check params["enhancePrompt"].getBool() == true

    let src = generateVideosSource(
      prompt = some("A robot dancing"),
      video = some(videoFromUri("gs://bucket/base.mp4"))
    )
    let srcJson = src.toJson()
    check srcJson["prompt"].getStr() == "A robot dancing"
    check srcJson["video"]["uri"].getStr() == "gs://bucket/base.mp4"

  test "parse generate videos operation response":
    let raw = %*{
      "name": "models/veo-2.0-generate-001/operations/op-123",
      "done": true,
      "metadata": {"progress": 100},
      "response": {
        "generateVideoResponse": {
          "generatedSamples": [
            {
              "video": {
                "uri": "gs://bucket/output.mp4",
                "encoding": "video/mp4"
              }
            }
          ],
          "raiMediaFilteredCount": 1,
          "raiMediaFilteredReasons": ["SAFETY"]
        }
      }
    }

    let operation = parseGenerateVideosOperation(raw)
    check operation.name == "models/veo-2.0-generate-001/operations/op-123"
    check operation.done.isSome
    check operation.done.get() == true
    check operation.result.isSome
    check operation.result.get().generatedVideos.len == 1
    check operation.result.get().generatedVideos[0].video.isSome
    check operation.result.get().generatedVideos[0].video.get().uri.get() == "gs://bucket/output.mp4"
    check operation.result.get().generatedVideos[0].video.get().mimeType.get() == "video/mp4"
    check operation.result.get().raiMediaFilteredCount.isSome
    check operation.result.get().raiMediaFilteredCount.get() == 1
    check operation.result.get().raiMediaFilteredReasons == @["SAFETY"]

  test "generateVideos sends predictLongRunning request":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestPath = ""
      var requestValidated = false

      proc cb(req: Request) {.async, gcsafe.} =
        requestPath = req.url.path
        let requestJson = parseJson(req.body)
        try:
          requestValidated = (
            requestJson["instances"][0]["prompt"].getStr() == "A neon cat" and
            requestJson["parameters"]["sampleCount"].getInt() == 1 and
            requestJson["parameters"]["durationSeconds"].getInt() == 6
          )
        except CatchableError:
          requestValidated = false

        let responseJson = %*{
          "name": "models/veo-2.0-generate-001/operations/op-1",
          "done": false
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

      let operation = await c.generateVideos(
        model = "veo-2.0-generate-001",
        prompt = "A neon cat",
        config = generateVideosConfig(
          numberOfVideos = some(1),
          durationSeconds = some(6)
        )
      )

      c.close()
      server.close()

      check requestPath.endsWith("/v1beta/models/veo-2.0-generate-001:predictLongRunning")
      check requestValidated
      check operation.name == "models/veo-2.0-generate-001/operations/op-1"
      check operation.done.isSome
      check operation.done.get() == false

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "video with uri and bytes sends uri only":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestValidated = false

      proc cb(req: Request) {.async, gcsafe.} =
        let requestJson = parseJson(req.body)
        try:
          let videoNode = requestJson["instances"][0]["video"]
          requestValidated = (
            videoNode["uri"].getStr() == "gs://bucket/base.mp4" and
            videoNode["encoding"].getStr() == "video/mp4" and
            not videoNode.hasKey("encodedVideo")
          )
        except CatchableError:
          requestValidated = false

        let responseJson = %*{
          "name": "models/veo-2.0-generate-001/operations/op-1",
          "done": false
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

      discard await c.generateVideos(
        model = "veo-2.0-generate-001",
        video = Video(
          uri: some("gs://bucket/base.mp4"),
          bytesBase64: some("AQID"),
          mimeType: some("video/mp4")
        )
      )

      c.close()
      server.close()

      check requestValidated

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "video extension via source and polling":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestCount = 0
      var generateValidated = false
      var pollValidated = false

      proc cb(req: Request) {.async, gcsafe.} =
        inc(requestCount)

        var responseJson: JsonNode
        if requestCount == 1:
          let requestJson = parseJson(req.body)
          try:
            generateValidated = (
              req.reqMethod == HttpPost and
              req.url.path.endsWith("/v1beta/models/veo-2.0-generate-001:predictLongRunning") and
              requestJson["instances"][0]["prompt"].getStr() == "Make it sunny" and
              requestJson["instances"][0]["video"]["uri"].getStr() == "gs://bucket/base.mp4" and
              requestJson["instances"][0]["video"]["encoding"].getStr() == "video/mp4" and
              requestJson["parameters"]["sampleCount"].getInt() == 1
            )
          except CatchableError:
            generateValidated = false

          responseJson = %*{
            "name": "models/veo-2.0-generate-001/operations/op-2",
            "done": false,
            "metadata": {"progress": 10}
          }
        else:
          pollValidated = (
            req.reqMethod == HttpGet and
            req.url.path.endsWith("/v1beta/models/veo-2.0-generate-001/operations/op-2")
          )

          responseJson = %*{
            "name": "models/veo-2.0-generate-001/operations/op-2",
            "done": true,
            "response": {
              "generateVideoResponse": {
                "generatedSamples": [
                  {
                    "video": {
                      "uri": "gs://bucket/final.mp4",
                      "encoding": "video/mp4"
                    }
                  }
                ]
              }
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

      let initialOperation = await c.generateVideos(
        model = "veo-2.0-generate-001",
        source = generateVideosSource(
          prompt = some("Make it sunny"),
          video = some(videoFromUri("gs://bucket/base.mp4", some("video/mp4")))
        ),
        config = generateVideosConfig(numberOfVideos = some(1))
      )

      let finalOperation = await c.getOperation(initialOperation)

      c.close()
      server.close()

      check requestCount == 2
      check generateValidated
      check pollValidated
      check finalOperation.done.isSome
      check finalOperation.done.get() == true
      check finalOperation.result.isSome
      check finalOperation.result.get().generatedVideos.len == 1
      check finalOperation.result.get().generatedVideos[0].video.isSome
      check finalOperation.result.get().generatedVideos[0].video.get().uri.get() == "gs://bucket/final.mp4"

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()
