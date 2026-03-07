import std/[asyncdispatch, asynchttpserver, json, nativesockets, options, os, strutils, unittest]

import ../src/nim_genai/[client, types]

suite "Files API":
  test "extract file resources and list metadata":
    let raw = %*{
      "files": [
        {
          "name": "files/abc123",
          "displayName": "sample",
          "mimeType": "text/plain",
          "sizeBytes": 42,
          "uri": "gs://bucket/abc123",
          "downloadUri": "https://download.example/abc123",
          "state": "ACTIVE"
        },
        {
          "name": "files/def456",
          "state": {"name": "PROCESSING"}
        }
      ],
      "nextPageToken": "next-page"
    }

    let files = extractFiles(raw)
    check files.len == 2
    check files[0].name.isSome and files[0].name.get() == "files/abc123"
    check files[0].mimeType.isSome and files[0].mimeType.get() == "text/plain"
    check files[0].sizeBytes.isSome and files[0].sizeBytes.get() == 42
    check files[0].state.isSome and files[0].state.get() == "ACTIVE"
    check files[1].state.isSome and files[1].state.get() == "PROCESSING"

    let nextPageToken = extractListFilesNextPageToken(raw)
    check nextPageToken.isSome and nextPageToken.get() == "next-page"

  test "getFile normalizes names and parses response":
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
          "name": "files/abc123",
          "mimeType": "application/pdf",
          "sizeBytes": 1024
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
      let file = await c.getFile("https://generativelanguage.googleapis.com/v1beta/files/abc123")

      c.close()
      server.close()

      check requestMethod == "HttpGet"
      check requestPath.endsWith("/v1beta/files/abc123")
      check file.name.isSome and file.name.get() == "files/abc123"
      check file.mimeType.isSome and file.mimeType.get() == "application/pdf"
      check file.sizeBytes.isSome and file.sizeBytes.get() == 1024

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "listFiles supports pagination options":
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
          "files": [
            {"name": "files/one"},
            {"name": "files/two"}
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
      let response = await c.listFiles(
        listFilesConfig(
          pageSize = some(2),
          pageToken = some("page-1")
        )
      )

      c.close()
      server.close()

      check requestMethod == "HttpGet"
      check requestPath.endsWith("/v1beta/files")
      check requestQuery.contains("pageSize=2")
      check requestQuery.contains("pageToken=page-1")
      check response.files.len == 2
      check response.files[0].name.isSome and response.files[0].name.get() == "files/one"
      check response.nextPageToken.isSome and response.nextPageToken.get() == "next-token"

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "deleteFile sends delete request":
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
      let response = await c.deleteFile("files/abc123")

      c.close()
      server.close()

      check requestMethod == "HttpDelete"
      check requestPath.endsWith("/v1beta/files/abc123")
      check response.raw.kind == JObject

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "uploadFile performs resumable upload flow":
    proc runRoundTrip() {.async.} =
      let server = newAsyncHttpServer()
      server.listen(Port(0), "127.0.0.1")
      let port = server.getPort.uint16

      var requestCount = 0
      var startRequestValidated = false
      var uploadRequestValidated = false

      proc cb(req: Request) {.async, gcsafe.} =
        inc(requestCount)

        if req.url.path.endsWith("/upload/v1beta/files"):
          let requestJson = parseJson(req.body)
          try:
            startRequestValidated = (
              requestJson.kind == JObject and
              requestJson["file"]["name"].getStr() == "files/my-upload" and
              requestJson["file"]["displayName"].getStr() == "My Upload" and
              requestJson["file"]["mimeType"].getStr() == "text/plain" and
              req.headers["x-goog-upload-protocol"] == "resumable" and
              req.headers["x-goog-upload-command"] == "start" and
              req.headers["x-goog-upload-header-content-type"] == "text/plain"
            )
          except CatchableError:
            startRequestValidated = false

          var headers = newHttpHeaders()
          headers["x-goog-upload-url"] = "http://127.0.0.1:" & $port & "/upload-session/abc"
          headers["Content-Type"] = "application/json"
          await req.respond(Http200, "{}", headers)
          return

        if req.url.path == "/upload-session/abc":
          try:
            uploadRequestValidated = (
              req.headers["x-goog-upload-command"] == "upload, finalize" and
              req.headers["x-goog-upload-offset"] == "0" and
              req.body == "hello"
            )
          except CatchableError:
            uploadRequestValidated = false

          let responseJson = %*{
            "file": {
              "name": "files/uploaded123",
              "mimeType": "text/plain",
              "sizeBytes": 5
            }
          }
          var headers = newHttpHeaders()
          headers["x-goog-upload-status"] = "final"
          headers["Content-Type"] = "application/json"
          await req.respond(Http200, $responseJson, headers)
          return

        await req.respond(Http404, "not found")

      asyncCheck server.acceptRequest(cb)

      let tempFile = getTempDir() / "nim_genai_upload_test.txt"
      writeFile(tempFile, "hello")

      let c = newClient(
        apiKey = "test-key",
        baseUrl = "http://127.0.0.1:" & $port & "/",
        apiVersion = "v1beta"
      )
      let file = await c.uploadFile(
        tempFile,
        uploadFileConfig(
          name = some("my-upload"),
          displayName = some("My Upload")
        )
      )

      c.close()
      server.close()
      removeFile(tempFile)

      check requestCount == 2
      check startRequestValidated
      check uploadRequestValidated
      check file.name.isSome and file.name.get() == "files/uploaded123"
      check file.mimeType.isSome and file.mimeType.get() == "text/plain"
      check file.sizeBytes.isSome and file.sizeBytes.get() == 5

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "downloadFile fetches bytes":
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
        var headers = newHttpHeaders()
        headers["Content-Type"] = "application/octet-stream"
        await req.respond(Http200, "BINARY_DATA", headers)

      asyncCheck server.acceptRequest(cb)

      let c = newClient(
        apiKey = "test-key",
        baseUrl = "http://127.0.0.1:" & $port & "/",
        apiVersion = "v1beta"
      )
      let data = await c.downloadFile("files/abc123")

      c.close()
      server.close()

      check requestMethod == "HttpGet"
      check requestPath.endsWith("/v1beta/files/abc123:download")
      check requestQuery == "alt=media"
      check data == "BINARY_DATA"

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "registerFiles sends auth headers and parses response":
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
            requestJson["uris"].kind == JArray and
            requestJson["uris"].len == 2 and
            requestJson["uris"][0].getStr() == "gs://bucket/one.txt" and
            requestJson["uris"][1].getStr() == "gs://bucket/two.txt" and
            req.headers["authorization"] == "Bearer token-123" and
            req.headers["x-goog-user-project"] == "quota-project-1"
          )
        except CatchableError:
          requestValidated = false

        let responseJson = %*{
          "files": [
            {
              "name": "files/registered-1",
              "uri": "gs://bucket/one.txt",
              "mimeType": "text/plain"
            },
            {
              "name": "files/registered-2",
              "uri": "gs://bucket/two.txt",
              "mimeType": "text/plain"
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
      let response = await c.registerFiles(
        uris = @["gs://bucket/one.txt", "gs://bucket/two.txt"],
        config = registerFilesConfig(
          accessToken = some("token-123"),
          userProject = some("quota-project-1")
        )
      )

      c.close()
      server.close()

      check requestMethod == "HttpPost"
      check requestPath.endsWith("/v1beta/files:register")
      check requestValidated
      check response.files.len == 2
      check response.files[0].name.isSome and response.files[0].name.get() == "files/registered-1"
      check response.files[1].uri.isSome and response.files[1].uri.get() == "gs://bucket/two.txt"

    try:
      waitFor runRoundTrip()
    except OSError:
      skip()

  test "registerFiles validates required access token":
    proc runInvalidConfig() {.async.} =
      let c = newClient(
        apiKey = "test-key",
        baseUrl = "http://127.0.0.1:1/",
        apiVersion = "v1beta"
      )
      defer: c.close()

      discard await c.registerFiles(
        uris = @["gs://bucket/one.txt"],
        config = registerFilesConfig()
      )

    expect(ValueError):
      waitFor runInvalidConfig()
