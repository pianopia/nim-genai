import std/[asyncdispatch, asyncstreams, httpclient, json, options, os, strutils]

import ./types
import ./errors
import ./streaming

const
  DefaultBaseUrl* = "https://generativelanguage.googleapis.com/"
  DefaultApiVersion* = "v1beta"
  DefaultUserAgent* = "nim-genai/0.1.0"

type
  Client* = ref object
    apiKey*: string
    baseUrl*: string
    apiVersion*: string
    userAgent*: string
    http*: AsyncHttpClient

proc joinUrl(base: string, path: string): string =
  var b = base
  if not b.endsWith("/"):
    b.add("/")
  var p = path
  if p.startsWith("/"):
    p = p[1..^1]
  result = b & p

proc normalizeModelPath(model: string): string =
  if model.startsWith("models/") or model.startsWith("tunedModels/"):
    result = model
  else:
    result = "models/" & model

proc resolveApiKey(apiKey: string): string =
  if apiKey.len > 0:
    return apiKey
  let googleKey = getEnv("GOOGLE_API_KEY")
  if googleKey.len > 0:
    return googleKey
  let geminiKey = getEnv("GEMINI_API_KEY")
  return geminiKey

proc newClient*(apiKey: string = "", baseUrl = DefaultBaseUrl,
                apiVersion = DefaultApiVersion,
                userAgent = DefaultUserAgent): Client =
  let key = resolveApiKey(apiKey).strip()
  if key.len == 0:
    raise newException(ValueError,
      "API key is required. Set apiKey or GEMINI_API_KEY/GOOGLE_API_KEY.")

  var headers = newHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["x-goog-api-key"] = key

  result = Client(
    apiKey: key,
    baseUrl: baseUrl,
    apiVersion: apiVersion,
    userAgent: userAgent,
    http: newAsyncHttpClient(userAgent = userAgent, headers = headers)
  )

proc close*(client: Client) =
  if client.isNil:
    return
  client.http.close()

proc optionalSystemInstruction(systemInstruction: string): Option[Content] =
  if systemInstruction.len == 0:
    result = none(Content)
  else:
    result = some(systemInstructionFromText(systemInstruction))

proc buildGenerateContentRequest(contents: seq[Content],
                                 config: GenerateContentConfig,
                                 systemInstruction: Option[Content]): JsonNode =
  result = newJObject()

  let contentsNode = newJArray()
  for content in contents:
    contentsNode.add(content.toJson())
  result["contents"] = contentsNode

  if systemInstruction.isSome:
    result["systemInstruction"] = systemInstruction.get().toJson()

  let configNode = config.toJson()
  if configNode.len > 0:
    result["generationConfig"] = configNode

proc buildGenerateContentUrl(client: Client, model: string, stream: bool): string =
  let modelPath = normalizeModelPath(model)
  var path = client.apiVersion & "/" & modelPath
  if stream:
    path.add(":streamGenerateContent?alt=sse")
  else:
    path.add(":generateContent")
  result = joinUrl(client.baseUrl, path)

proc extractErrorCode(raw: JsonNode, fallbackCode: int): int =
  result = fallbackCode
  try:
    if raw.kind == JObject and raw.hasKey("error"):
      let err = raw["error"]
      if err.kind == JObject and err.hasKey("code"):
        result = err["code"].getInt()
  except CatchableError:
    discard

proc parsePayloadToResponse(payload: string, fallbackCode: int): GenerateContentResponse =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = GenerateContentResponse(
    raw: raw,
    text: extractText(raw),
    functionCalls: extractFunctionCalls(raw)
  )

proc generateContentInternal(client: Client, model: string, contents: seq[Content],
                             config: GenerateContentConfig,
                             systemInstruction: Option[Content]): Future[GenerateContentResponse]
                             {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")
  if contents.len == 0:
    raise newException(ValueError, "contents is required")

  let url = buildGenerateContentUrl(client, model, stream = false)

  let bodyJson = buildGenerateContentRequest(contents, config, systemInstruction)
  let bodyStr = $bodyJson

  let resp = await client.http.request(url, HttpPost, body = bodyStr)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parsePayloadToResponse(respBody, statusCode)

proc generateContent*(client: Client, model: string, contents: seq[Content],
                      config: GenerateContentConfig = GenerateContentConfig(),
                      systemInstruction: string = ""): Future[GenerateContentResponse]
                      {.async.} =
  result = await generateContentInternal(
    client,
    model,
    contents,
    config,
    optionalSystemInstruction(systemInstruction)
  )

proc generateContent*(client: Client, model: string, contents: seq[Content],
                      config: GenerateContentConfig,
                      systemInstruction: Content): Future[GenerateContentResponse]
                      {.async.} =
  result = await generateContentInternal(
    client,
    model,
    contents,
    config,
    some(systemInstruction)
  )

proc generateContent*(client: Client, model: string, prompt: string,
                      config: GenerateContentConfig = GenerateContentConfig(),
                      systemInstruction: string = ""): Future[GenerateContentResponse]
                      {.async.} =
  let content = contentFromText(prompt)
  result = await client.generateContent(model, @[content], config, systemInstruction)

proc generateContent*(client: Client, model: string, prompt: string,
                      config: GenerateContentConfig,
                      systemInstruction: Content): Future[GenerateContentResponse]
                      {.async.} =
  let content = contentFromText(prompt)
  result = await client.generateContent(model, @[content], config, systemInstruction)

proc generateContentStreamInternal(client: Client, model: string, contents: seq[Content],
                                   config: GenerateContentConfig,
                                   systemInstruction: Option[Content]): FutureStream[GenerateContentResponse] =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")
  if contents.len == 0:
    raise newException(ValueError, "contents is required")

  let stream = newFutureStream[GenerateContentResponse]("generateContentStream")
  result = stream

  proc runStream() {.async.} =
    try:
      let url = buildGenerateContentUrl(client, model, stream = true)
      let bodyJson = buildGenerateContentRequest(contents, config, systemInstruction)
      let resp = await client.http.request(url, HttpPost, body = $bodyJson)
      let statusCode = resp.code.int

      if statusCode < 200 or statusCode >= 300:
        let respBody = await resp.body()
        raise newGenAIError(statusCode, respBody)

      var parser: SseLineParser
      var done = false

      while not done:
        let (hasValue, chunk) = await resp.bodyStream.read()
        if not hasValue:
          break
        let payloads = parser.consumeSseChunk(chunk)
        for payload in payloads:
          if payload.len == 0:
            continue
          if payload == "[DONE]":
            done = true
            break
          await stream.write(parsePayloadToResponse(payload, statusCode))

      if not done:
        let payloads = parser.flushSseChunkParser()
        for payload in payloads:
          if payload.len == 0 or payload == "[DONE]":
            continue
          await stream.write(parsePayloadToResponse(payload, statusCode))

      stream.complete()
    except CatchableError as exc:
      stream.fail(exc)

  asyncCheck runStream()

proc generateContentStream*(client: Client, model: string, contents: seq[Content],
                            config: GenerateContentConfig = GenerateContentConfig(),
                            systemInstruction: string = ""): FutureStream[GenerateContentResponse] =
  result = generateContentStreamInternal(
    client,
    model,
    contents,
    config,
    optionalSystemInstruction(systemInstruction)
  )

proc generateContentStream*(client: Client, model: string, contents: seq[Content],
                            config: GenerateContentConfig,
                            systemInstruction: Content): FutureStream[GenerateContentResponse] =
  result = generateContentStreamInternal(
    client,
    model,
    contents,
    config,
    some(systemInstruction)
  )

proc generateContentStream*(client: Client, model: string, prompt: string,
                            config: GenerateContentConfig = GenerateContentConfig(),
                            systemInstruction: string = ""): FutureStream[GenerateContentResponse] =
  result = client.generateContentStream(
    model = model,
    contents = @[contentFromText(prompt)],
    config = config,
    systemInstruction = systemInstruction
  )

proc generateContentStream*(client: Client, model: string, prompt: string,
                            config: GenerateContentConfig,
                            systemInstruction: Content): FutureStream[GenerateContentResponse] =
  result = client.generateContentStream(
    model = model,
    contents = @[contentFromText(prompt)],
    config = config,
    systemInstruction = systemInstruction
  )
