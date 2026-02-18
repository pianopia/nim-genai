import std/[asyncdispatch, asyncstreams, httpclient, json, options, os, strutils, tables]

import ./types
import ./errors
import ./streaming

const
  DefaultBaseUrl* = "https://generativelanguage.googleapis.com/"
  DefaultApiVersion* = "v1beta"
  DefaultUserAgent* = "nim-genai/0.1.0"

type
  FunctionHandler* = proc(args: JsonNode): Future[JsonNode] {.closure, gcsafe.}
  FunctionHandlerMap* = Table[string, FunctionHandler]

  Client* = ref object
    apiKey*: string
    baseUrl*: string
    apiVersion*: string
    userAgent*: string
    http*: AsyncHttpClient

const
  DefaultMaxRemoteCallsAfc = 10

proc newFunctionHandlerMap*(): FunctionHandlerMap =
  initTable[string, FunctionHandler]()

proc setFunctionHandler*(handlers: var FunctionHandlerMap, name: string,
                         handler: FunctionHandler) =
  if name.len == 0:
    raise newException(ValueError, "handler name is required")
  handlers[name] = handler

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

proc buildEmbedContentRequest(modelPath: string, contents: seq[Content],
                              config: EmbedContentConfig): JsonNode =
  result = newJObject()
  let requestsNode = newJArray()
  let configNode = config.toJson()
  for content in contents:
    let requestNode = newJObject()
    requestNode["model"] = %modelPath
    requestNode["content"] = content.toJson()
    for key, value in configNode:
      requestNode[key] = value
    requestsNode.add(requestNode)
  result["requests"] = requestsNode

proc buildGenerateContentUrl(client: Client, model: string, stream: bool): string =
  let modelPath = normalizeModelPath(model)
  var path = client.apiVersion & "/" & modelPath
  if stream:
    path.add(":streamGenerateContent?alt=sse")
  else:
    path.add(":generateContent")
  result = joinUrl(client.baseUrl, path)

proc buildEmbedContentUrl(client: Client, model: string): string =
  let modelPath = normalizeModelPath(model)
  let path = client.apiVersion & "/" & modelPath & ":batchEmbedContents"
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

proc parseEmbedPayloadToResponse(payload: string, fallbackCode: int): EmbedContentResponse =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = EmbedContentResponse(
    raw: raw,
    embeddings: extractEmbeddings(raw),
    metadata: extractEmbedContentMetadata(raw)
  )

proc shouldDisableAfc(config: GenerateContentConfig): bool =
  if config.automaticFunctionCalling.isSome:
    let afc = config.automaticFunctionCalling.get()
    if afc.maximumRemoteCalls.isSome and afc.maximumRemoteCalls.get() <= 0:
      return true
    if afc.disable.isSome:
      return afc.disable.get()
  return false

proc getMaxRemoteCallsAfc(config: GenerateContentConfig): int =
  if shouldDisableAfc(config):
    return 0
  if config.automaticFunctionCalling.isSome:
    let afc = config.automaticFunctionCalling.get()
    if afc.maximumRemoteCalls.isSome:
      return afc.maximumRemoteCalls.get()
  return DefaultMaxRemoteCallsAfc

proc shouldAppendAfcHistory(config: GenerateContentConfig): bool =
  if config.automaticFunctionCalling.isSome:
    let afc = config.automaticFunctionCalling.get()
    if afc.ignoreCallHistory.isSome:
      return not afc.ignoreCallHistory.get()
  return true

proc getFunctionResponseParts(response: GenerateContentResponse,
                              functionHandlers: FunctionHandlerMap): Future[seq[Part]] {.async.} =
  for functionCall in response.functionCalls:
    if not functionHandlers.hasKey(functionCall.name):
      raise newException(KeyError, "Missing function handler: " & functionCall.name)
    let handler = functionHandlers[functionCall.name]
    var handlerResponse = newJObject()
    try:
      let handlerResult = await handler(functionCall.args)
      if handlerResult.isNil:
        handlerResponse["result"] = newJNull()
      else:
        handlerResponse["result"] = handlerResult
    except CatchableError as exc:
      handlerResponse["error"] = %exc.msg
    result.add(partFromFunctionResponse(functionCall.name, handlerResponse))

proc functionCallContentFromResponse(response: GenerateContentResponse): Option[Content] =
  if response.functionCalls.len == 0:
    return none(Content)
  var parts: seq[Part] = @[]
  for functionCall in response.functionCalls:
    parts.add(partFromFunctionCall(functionCall.name, functionCall.args))
  result = some(Content(role: "model", parts: parts))

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

proc embedContentInternal(client: Client, model: string, contents: seq[Content],
                          config: EmbedContentConfig): Future[EmbedContentResponse]
                          {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")
  if contents.len == 0:
    raise newException(ValueError, "contents is required")

  let modelPath = normalizeModelPath(model)
  let bodyJson = buildEmbedContentRequest(modelPath, contents, config)
  let url = buildEmbedContentUrl(client, model)

  let resp = await client.http.request(url, HttpPost, body = $bodyJson)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseEmbedPayloadToResponse(respBody, statusCode)

proc generateContentAfcInternal(client: Client, model: string,
                                contents: seq[Content],
                                functionHandlers: FunctionHandlerMap,
                                config: GenerateContentConfig,
                                systemInstruction: Option[Content]): Future[GenerateContentResponse]
                                {.async.} =
  if functionHandlers.len == 0 or shouldDisableAfc(config):
    return await generateContentInternal(
      client, model, contents, config, systemInstruction
    )

  var requestContents: seq[Content] = @[]
  requestContents.add(contents)
  var remainingRemoteCalls = getMaxRemoteCallsAfc(config)
  if remainingRemoteCalls <= 0:
    return await generateContentInternal(
      client, model, contents, config, systemInstruction
    )

  let appendHistory = shouldAppendAfcHistory(config)
  var afcHistory: seq[Content] = @[]
  if appendHistory:
    afcHistory.add(requestContents)

  var response: GenerateContentResponse
  while remainingRemoteCalls > 0:
    response = await generateContentInternal(
      client, model, requestContents, config, systemInstruction
    )
    if response.functionCalls.len == 0:
      break

    let functionResponseParts = await getFunctionResponseParts(response, functionHandlers)
    if functionResponseParts.len == 0:
      break

    dec(remainingRemoteCalls)
    let functionCallContent = functionCallContentFromResponse(response)
    let functionResponseContent = Content(role: "user", parts: functionResponseParts)

    if functionCallContent.isSome:
      requestContents.add(functionCallContent.get())
      if appendHistory:
        afcHistory.add(functionCallContent.get())
    requestContents.add(functionResponseContent)
    if appendHistory:
      afcHistory.add(functionResponseContent)

  if appendHistory:
    response.automaticFunctionCallingHistory = afcHistory
  return response

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

proc generateContentAfc*(client: Client, model: string, contents: seq[Content],
                         functionHandlers: FunctionHandlerMap,
                         config: GenerateContentConfig = GenerateContentConfig(),
                         systemInstruction: string = ""): Future[GenerateContentResponse]
                         {.async.} =
  result = await generateContentAfcInternal(
    client,
    model,
    contents,
    functionHandlers,
    config,
    optionalSystemInstruction(systemInstruction)
  )

proc generateContentAfc*(client: Client, model: string, contents: seq[Content],
                         functionHandlers: FunctionHandlerMap,
                         config: GenerateContentConfig,
                         systemInstruction: Content): Future[GenerateContentResponse]
                         {.async.} =
  result = await generateContentAfcInternal(
    client,
    model,
    contents,
    functionHandlers,
    config,
    some(systemInstruction)
  )

proc generateContentAfc*(client: Client, model: string, prompt: string,
                         functionHandlers: FunctionHandlerMap,
                         config: GenerateContentConfig = GenerateContentConfig(),
                         systemInstruction: string = ""): Future[GenerateContentResponse]
                         {.async.} =
  result = await client.generateContentAfc(
    model = model,
    contents = @[contentFromText(prompt)],
    functionHandlers = functionHandlers,
    config = config,
    systemInstruction = systemInstruction
  )

proc generateContentAfc*(client: Client, model: string, prompt: string,
                         functionHandlers: FunctionHandlerMap,
                         config: GenerateContentConfig,
                         systemInstruction: Content): Future[GenerateContentResponse]
                         {.async.} =
  result = await client.generateContentAfc(
    model = model,
    contents = @[contentFromText(prompt)],
    functionHandlers = functionHandlers,
    config = config,
    systemInstruction = systemInstruction
  )

proc embedContent*(client: Client, model: string, contents: seq[Content],
                   config: EmbedContentConfig = EmbedContentConfig()): Future[EmbedContentResponse]
                   {.async.} =
  result = await embedContentInternal(client, model, contents, config)

proc embedContent*(client: Client, model: string, content: Content,
                   config: EmbedContentConfig = EmbedContentConfig()): Future[EmbedContentResponse]
                   {.async.} =
  result = await embedContentInternal(client, model, @[content], config)

proc embedContent*(client: Client, model: string, text: string,
                   config: EmbedContentConfig = EmbedContentConfig()): Future[EmbedContentResponse]
                   {.async.} =
  result = await embedContentInternal(client, model, @[contentFromText(text)], config)

proc embedContent*(client: Client, model: string, texts: seq[string],
                   config: EmbedContentConfig = EmbedContentConfig()): Future[EmbedContentResponse]
                   {.async.} =
  var contents: seq[Content] = @[]
  for text in texts:
    contents.add(contentFromText(text))
  result = await embedContentInternal(client, model, contents, config)

proc embed*(client: Client, model: string, contents: seq[Content],
            config: EmbedContentConfig = EmbedContentConfig()): Future[EmbedContentResponse]
            {.async.} =
  result = await client.embedContent(model, contents, config)

proc embed*(client: Client, model: string, content: Content,
            config: EmbedContentConfig = EmbedContentConfig()): Future[EmbedContentResponse]
            {.async.} =
  result = await client.embedContent(model, content, config)

proc embed*(client: Client, model: string, text: string,
            config: EmbedContentConfig = EmbedContentConfig()): Future[EmbedContentResponse]
            {.async.} =
  result = await client.embedContent(model, text, config)

proc embed*(client: Client, model: string, texts: seq[string],
            config: EmbedContentConfig = EmbedContentConfig()): Future[EmbedContentResponse]
            {.async.} =
  result = await client.embedContent(model, texts, config)

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
