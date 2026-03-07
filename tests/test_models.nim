import std/[asyncdispatch, asynchttpserver, json, nativesockets, options, strutils, unittest]

import ../src/nim_genai/[client, types]

suite "Models API":
  test "extract model list response":
    let raw = %*{
      "models": [
        {
          "name": "models/gemini-2.5-flash",
          "displayName": "Gemini 2.5 Flash",
          "description": "Fast model",
          "inputTokenLimit": 1234,
          "outputTokenLimit": 567,
          "supportedGenerationMethods": ["generateContent", "countTokens"],
          "temperature": 1.0,
          "maxTemperature": 2.0,
          "topP": 0.95,
          "topK": 40,
          "thinking": true
        }
      ],
      "nextPageToken": "next-page"
    }

    let models = extractModels(raw)
    check models.len == 1
    check models[0].name.isSome and models[0].name.get() == "models/gemini-2.5-flash"
    check models[0].displayName.isSome and models[0].displayName.get() == "Gemini 2.5 Flash"
    check models[0].supportedActions.len == 2
    check models[0].inputTokenLimit.isSome and models[0].inputTokenLimit.get() == 1234
    check models[0].thinking.isSome and models[0].thinking.get()

    let nextPageToken = extractListModelsNextPageToken(raw)
    check nextPageToken.isSome and nextPageToken.get() == "next-page"

  test "getModel sends request and parses model":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestPath = ""
      var requestMethod = ""

      proc cb(req: Request) {.async, gcsafe.} =
        requestPath = req.url.path
        requestMethod = $req.reqMethod

        let responseJson = %*{
          "name": "models/gemini-2.5-flash",
          "displayName": "Gemini 2.5 Flash",
          "description": "Fast model",
          "inputTokenLimit": 1000,
          "outputTokenLimit": 8000
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
      let model = await c.getModel("gemini-2.5-flash")

      c.close()
      server.close()

      check requestMethod == "HttpGet"
      check requestPath.endsWith("/v1beta/models/gemini-2.5-flash")
      check model.name.isSome and model.name.get() == "models/gemini-2.5-flash"
      check model.displayName.isSome and model.displayName.get() == "Gemini 2.5 Flash"
      check model.inputTokenLimit.isSome and model.inputTokenLimit.get() == 1000

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "listModels supports query options and tuned models":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestPath = ""
      var requestQuery = ""
      var requestMethod = ""

      proc cb(req: Request) {.async, gcsafe.} =
        requestPath = req.url.path
        requestQuery = req.url.query
        requestMethod = $req.reqMethod

        let responseJson = %*{
          "tunedModels": [
            {"name": "tunedModels/my-model", "displayName": "My Tuned Model"}
          ],
          "nextPageToken": "next-token"
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
      let response = await c.listModels(
        listModelsConfig(
          pageSize = some(2),
          pageToken = some("p-1"),
          filter = some("name:tuned"),
          queryBase = some(false)
        )
      )

      c.close()
      server.close()

      check requestMethod == "HttpGet"
      check requestPath.endsWith("/v1beta/tunedModels")
      check requestQuery.contains("pageSize=2")
      check requestQuery.contains("pageToken=p-1")
      check requestQuery.contains("filter=name:tuned")
      check response.models.len == 1
      check response.models[0].name.isSome and response.models[0].name.get() == "tunedModels/my-model"
      check response.nextPageToken.isSome and response.nextPageToken.get() == "next-token"

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "updateModel sends patch request body and parses response":
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
            requestJson["displayName"].getStr() == "Renamed Tuned Model" and
            requestJson["description"].getStr() == "Updated description" and
            requestJson["defaultCheckpointId"].getStr() == "checkpoint-2"
          )
        except CatchableError:
          requestValidated = false

        let responseJson = %*{
          "name": "tunedModels/my-model",
          "displayName": "Renamed Tuned Model",
          "description": "Updated description"
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
      let model = await c.updateModel(
        "tunedModels/my-model",
        updateModelConfig(
          displayName = some("Renamed Tuned Model"),
          description = some("Updated description"),
          defaultCheckpointId = some("checkpoint-2")
        )
      )

      c.close()
      server.close()

      check requestMethod == "HttpPatch"
      check requestPath.endsWith("/v1beta/tunedModels/my-model")
      check requestValidated
      check model.name.isSome and model.name.get() == "tunedModels/my-model"
      check model.displayName.isSome and model.displayName.get() == "Renamed Tuned Model"
      check model.description.isSome and model.description.get() == "Updated description"

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "deleteModel sends delete request":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestPath = ""
      var requestMethod = ""

      proc cb(req: Request) {.async, gcsafe.} =
        requestPath = req.url.path
        requestMethod = $req.reqMethod
        var headers = newHttpHeaders()
        headers["Content-Type"] = "application/json"
        await req.respond(Http200, "{}", headers)

      asyncCheck server.acceptRequest(cb)

      let c = newClient(
        apiKey = "test-key",
        baseUrl = "http://127.0.0.1:" & $port & "/",
        apiVersion = "v1beta"
      )
      let response = await c.deleteModel("tunedModels/my-model")

      c.close()
      server.close()

      check requestMethod == "HttpDelete"
      check requestPath.endsWith("/v1beta/tunedModels/my-model")
      check response.raw.kind == JObject

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()
