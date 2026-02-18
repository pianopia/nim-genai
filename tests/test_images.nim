import std/[asyncdispatch, asynchttpserver, json, nativesockets, options, strutils, unittest]

import ../src/nim_genai/[client, types]

suite "Image APIs":
  test "image helpers and config serialization":
    let image = imageFromBytes([1'u8, 2'u8, 3'u8], "image/png")
    check image.mimeType == "image/png"
    check image.bytesBase64 == "AQID"

    let generateCfg = generateImagesConfig(
      numberOfImages = some(2),
      outputMimeType = some("image/jpeg"),
      outputCompressionQuality = some(80)
    )
    let generateParams = generateCfg.toJson()
    check generateParams["sampleCount"].getInt() == 2
    check generateParams["outputOptions"]["mimeType"].getStr() == "image/jpeg"
    check generateParams["outputOptions"]["compressionQuality"].getInt() == 80

    let editCfg = editImageConfig(
      editMode = some("EDIT_MODE_INPAINT_INSERTION"),
      baseSteps = some(32)
    )
    let editParams = editCfg.toJson()
    check editParams["editMode"].getStr() == "EDIT_MODE_INPAINT_INSERTION"
    check editParams["editConfig"]["baseSteps"].getInt() == 32

    let upscaleCfg = upscaleImageConfig(
      enhanceInputImage = some(true),
      imagePreservationFactor = some(0.6)
    )
    let upscaleParams = upscaleCfg.toJson()
    check upscaleParams["upscaleConfig"]["enhanceInputImage"].getBool() == true
    check abs(upscaleParams["upscaleConfig"]["imagePreservationFactor"].getFloat() - 0.6) < 0.000001

  test "extract generated images and safety attributes":
    let raw = %*{
      "predictions": [
        {
          "bytesBase64Encoded": "AQID",
          "mimeType": "image/png",
          "raiFilteredReason": "NONE",
          "safetyAttributes": {
            "categories": ["Violence"],
            "scores": [0.02]
          },
          "contentType": "IMAGE"
        }
      ]
    }
    let generatedImages = extractGeneratedImages(raw)
    check generatedImages.len == 1
    check generatedImages[0].image.isSome
    check generatedImages[0].image.get().bytesBase64 == "AQID"
    check generatedImages[0].safetyAttributes.isSome
    check generatedImages[0].safetyAttributes.get().categories[0] == "Violence"

  test "generateImages sends predict request and parses response":
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
            requestJson["instances"][0]["prompt"].getStr() == "A red skateboard" and
            requestJson["parameters"]["sampleCount"].getInt() == 1 and
            requestJson["parameters"]["outputOptions"]["mimeType"].getStr() == "image/png" and
            requestJson["parameters"]["includeSafetyAttributes"].getBool() == true and
            requestJson["parameters"]["includeRaiReason"].getBool() == true
          )
        except CatchableError:
          requestValidated = false

        let responseJson = %*{
          "predictions": [
            {
              "bytesBase64Encoded": "AQID",
              "mimeType": "image/png",
              "safetyAttributes": {
                "categories": ["Violence"],
                "scores": [0.02]
              },
              "contentType": "IMAGE"
            },
            {
              "safetyAttributes": {
                "categories": ["Violence"],
                "scores": [0.00]
              },
              "contentType": "Positive Prompt"
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
      let response = await c.generateImages(
        model = "imagen-4.0-generate-001",
        prompt = "A red skateboard",
        config = generateImagesConfig(
          numberOfImages = some(1),
          outputMimeType = some("image/png"),
          includeSafetyAttributes = some(true),
          includeRaiReason = some(true)
        )
      )

      c.close()
      server.close()

      check requestPath.endsWith("/v1beta/models/imagen-4.0-generate-001:predict")
      check requestValidated
      check response.generatedImages.len == 1
      check response.generatedImages[0].image.isSome
      check response.generatedImages[0].image.get().bytesBase64 == "AQID"
      check response.positivePromptSafetyAttributes.isSome
      check response.positivePromptSafetyAttributes.get().contentType.get() == "Positive Prompt"

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "editImage sends edit mode and parses response":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestValidated = false

      proc cb(req: Request) {.async, gcsafe.} =
        let requestJson = parseJson(req.body)
        try:
          requestValidated = (
            requestJson["instances"][0]["prompt"].getStr() == "Replace background with beach" and
            requestJson["instances"][0]["image"]["bytesBase64Encoded"].getStr() == "AQID" and
            requestJson["parameters"]["mode"].getStr() == "edit" and
            requestJson["parameters"]["editMode"].getStr() == "EDIT_MODE_INPAINT_INSERTION" and
            requestJson["parameters"]["editConfig"]["baseSteps"].getInt() == 32
          )
        except CatchableError:
          requestValidated = false

        let responseJson = %*{
          "predictions": [
            {
              "bytesBase64Encoded": "BAUG",
              "mimeType": "image/png"
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
      let response = await c.editImage(
        model = "imagen-4.0-generate-001",
        prompt = "Replace background with beach",
        image = imageFromBase64("image/png", "AQID"),
        config = editImageConfig(
          editMode = some("EDIT_MODE_INPAINT_INSERTION"),
          baseSteps = some(32)
        )
      )

      c.close()
      server.close()

      check requestValidated
      check response.generatedImages.len == 1
      check response.generatedImages[0].image.isSome
      check response.generatedImages[0].image.get().bytesBase64 == "BAUG"

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "upscaleImage sends upscale mode and validates factor":
    expect ValueError:
      let c = newClient(apiKey = "test-key")
      defer: c.close()
      discard waitFor c.upscaleImage(
        model = "imagen-4.0-upscale-preview",
        image = imageFromBase64("image/png", "AQID"),
        upscaleFactor = "x3"
      )

  test "upscaleImage sends request and parses response":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestValidated = false

      proc cb(req: Request) {.async, gcsafe.} =
        let requestJson = parseJson(req.body)
        try:
          requestValidated = (
            requestJson["instances"][0]["image"]["bytesBase64Encoded"].getStr() == "AQID" and
            requestJson["parameters"]["mode"].getStr() == "upscale" and
            requestJson["parameters"]["sampleCount"].getInt() == 1 and
            requestJson["parameters"]["upscaleConfig"]["upscaleFactor"].getStr() == "x2" and
            requestJson["parameters"]["upscaleConfig"]["enhanceInputImage"].getBool() == true and
            abs(requestJson["parameters"]["upscaleConfig"]["imagePreservationFactor"].getFloat() - 0.6) < 0.000001
          )
        except CatchableError:
          requestValidated = false

        let responseJson = %*{
          "predictions": [
            {
              "bytesBase64Encoded": "BwgJ",
              "mimeType": "image/png"
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
      let response = await c.upscaleImage(
        model = "imagen-4.0-upscale-preview",
        image = imageFromBase64("image/png", "AQID"),
        upscaleFactor = "x2",
        config = upscaleImageConfig(
          enhanceInputImage = some(true),
          imagePreservationFactor = some(0.6)
        )
      )

      c.close()
      server.close()

      check requestValidated
      check response.generatedImages.len == 1
      check response.generatedImages[0].image.isSome
      check response.generatedImages[0].image.get().bytesBase64 == "BwgJ"

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()
