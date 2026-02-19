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

proc buildGenerateImagesRequest(prompt: string,
                                config: GenerateImagesConfig): JsonNode =
  result = newJObject()
  let instancesNode = newJArray()
  let instanceNode = newJObject()
  instanceNode["prompt"] = %prompt
  instancesNode.add(instanceNode)
  result["instances"] = instancesNode

  let paramsNode = config.toJson()
  if paramsNode.len > 0:
    result["parameters"] = paramsNode

proc buildEditImageRequest(prompt: string, image: Image,
                           config: EditImageConfig): JsonNode =
  result = newJObject()
  let instancesNode = newJArray()
  let instanceNode = newJObject()
  instanceNode["prompt"] = %prompt
  instanceNode["image"] = image.toJson()
  instancesNode.add(instanceNode)
  result["instances"] = instancesNode

  var paramsNode = config.toJson()
  paramsNode["mode"] = %"edit"
  if paramsNode.len > 0:
    result["parameters"] = paramsNode

proc buildUpscaleImageRequest(image: Image, upscaleFactor: string,
                              config: UpscaleImageConfig): JsonNode =
  result = newJObject()
  let instancesNode = newJArray()
  let instanceNode = newJObject()
  instanceNode["image"] = image.toJson()
  instancesNode.add(instanceNode)
  result["instances"] = instancesNode

  var paramsNode = config.toJson()
  paramsNode["mode"] = %"upscale"
  if not paramsNode.hasKey("sampleCount"):
    paramsNode["sampleCount"] = %1

  var upscaleConfigNode: JsonNode
  if paramsNode.hasKey("upscaleConfig") and paramsNode["upscaleConfig"].kind == JObject:
    upscaleConfigNode = paramsNode["upscaleConfig"]
  else:
    upscaleConfigNode = newJObject()
  upscaleConfigNode["upscaleFactor"] = %upscaleFactor
  paramsNode["upscaleConfig"] = upscaleConfigNode

  result["parameters"] = paramsNode

proc validateVideoInput(video: Video) =
  let hasUri = video.uri.isSome and video.uri.get().len > 0
  let hasBytes = video.bytesBase64.isSome and video.bytesBase64.get().len > 0
  if not hasUri and not hasBytes:
    raise newException(ValueError, "video must include uri or bytes")
  if hasBytes and (not video.mimeType.isSome or video.mimeType.get().len == 0):
    raise newException(ValueError, "video mimeType is required when bytes are provided")

proc validateGenerateVideosSource(source: GenerateVideosSource) =
  if source.prompt.isSome and source.prompt.get().len == 0:
    raise newException(ValueError, "source.prompt must not be empty")
  if source.image.isSome:
    let image = source.image.get()
    if image.bytesBase64.len == 0:
      raise newException(ValueError, "source.image bytes are required")
    if image.mimeType.len == 0:
      raise newException(ValueError, "source.image mimeType is required")
  if source.video.isSome:
    validateVideoInput(source.video.get())

  let hasPrompt = source.prompt.isSome and source.prompt.get().len > 0
  let hasImage = source.image.isSome
  let hasVideo = source.video.isSome
  if not hasPrompt and not hasImage and not hasVideo:
    raise newException(ValueError, "source must include prompt, image, or video")

proc normalizeVideoForMldev(video: Video): Video =
  ## Gemini Developer API does not support video bytes when URI is also provided.
  result = video
  let hasUri = video.uri.isSome and video.uri.get().len > 0
  let hasBytes = video.bytesBase64.isSome and video.bytesBase64.get().len > 0
  if hasUri and hasBytes:
    result.bytesBase64 = none(string)

proc buildGenerateVideosRequest(prompt: string,
                                image: Option[Image],
                                video: Option[Video],
                                source: Option[GenerateVideosSource],
                                config: GenerateVideosConfig): JsonNode =
  result = newJObject()
  let instancesNode = newJArray()
  let instanceNode = newJObject()

  if source.isSome:
    let sourceValue = source.get()
    if sourceValue.prompt.isSome:
      instanceNode["prompt"] = %sourceValue.prompt.get()
    if sourceValue.image.isSome:
      instanceNode["image"] = sourceValue.image.get().toJson()
    if sourceValue.video.isSome:
      instanceNode["video"] = normalizeVideoForMldev(sourceValue.video.get()).toJson()
  else:
    if prompt.len > 0:
      instanceNode["prompt"] = %prompt
    if image.isSome:
      instanceNode["image"] = image.get().toJson()
    if video.isSome:
      instanceNode["video"] = normalizeVideoForMldev(video.get()).toJson()

  if config.lastFrame.isSome:
    instanceNode["lastFrame"] = config.lastFrame.get().toJson()
  if config.referenceImages.len > 0:
    let referencesNode = newJArray()
    for referenceImage in config.referenceImages:
      referencesNode.add(referenceImage.toJson())
    instanceNode["referenceImages"] = referencesNode

  instancesNode.add(instanceNode)
  result["instances"] = instancesNode

  let paramsNode = config.toJson()
  if paramsNode.len > 0:
    result["parameters"] = paramsNode

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

proc buildPredictUrl(client: Client, model: string): string =
  let modelPath = normalizeModelPath(model)
  let path = client.apiVersion & "/" & modelPath & ":predict"
  result = joinUrl(client.baseUrl, path)

proc buildPredictLongRunningUrl(client: Client, model: string): string =
  let modelPath = normalizeModelPath(model)
  let path = client.apiVersion & "/" & modelPath & ":predictLongRunning"
  result = joinUrl(client.baseUrl, path)

proc buildOperationUrl(client: Client, operationName: string): string =
  var normalizedName = operationName
  if normalizedName.startsWith("/"):
    normalizedName = normalizedName[1 .. ^1]

  if normalizedName.startsWith("http://") or normalizedName.startsWith("https://"):
    return normalizedName

  if not normalizedName.startsWith(client.apiVersion & "/"):
    normalizedName = client.apiVersion & "/" & normalizedName
  result = joinUrl(client.baseUrl, normalizedName)

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

proc parseGenerateImagesPayloadToResponse(payload: string, fallbackCode: int): GenerateImagesResponse =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)

  let parsedImages = extractGeneratedImages(raw)
  var generatedImages: seq[GeneratedImage] = @[]
  var positivePromptSafetyAttributes = none(SafetyAttributes)
  for generatedImage in parsedImages:
    if generatedImage.safetyAttributes.isSome:
      let safety = generatedImage.safetyAttributes.get()
      if safety.contentType.isSome and safety.contentType.get() == "Positive Prompt":
        positivePromptSafetyAttributes = some(safety)
        continue
    generatedImages.add(generatedImage)

  result = GenerateImagesResponse(
    raw: raw,
    generatedImages: generatedImages,
    positivePromptSafetyAttributes: positivePromptSafetyAttributes
  )

proc parseEditImagePayloadToResponse(payload: string, fallbackCode: int): EditImageResponse =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = EditImageResponse(
    raw: raw,
    generatedImages: extractGeneratedImages(raw)
  )

proc parseUpscaleImagePayloadToResponse(payload: string, fallbackCode: int): UpscaleImageResponse =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = UpscaleImageResponse(
    raw: raw,
    generatedImages: extractGeneratedImages(raw)
  )

proc parseGenerateVideosOperationPayload(payload: string): GenerateVideosOperation =
  let raw = parseJson(payload)
  result = parseGenerateVideosOperation(raw)

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

proc generateImagesInternal(client: Client, model: string, prompt: string,
                            config: GenerateImagesConfig): Future[GenerateImagesResponse]
                            {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")
  if prompt.len == 0:
    raise newException(ValueError, "prompt is required")

  let url = buildPredictUrl(client, model)
  let bodyJson = buildGenerateImagesRequest(prompt, config)

  let resp = await client.http.request(url, HttpPost, body = $bodyJson)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseGenerateImagesPayloadToResponse(respBody, statusCode)

proc editImageInternal(client: Client, model: string, prompt: string,
                       image: Image, config: EditImageConfig): Future[EditImageResponse]
                       {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")
  if prompt.len == 0:
    raise newException(ValueError, "prompt is required")
  if image.bytesBase64.len == 0:
    raise newException(ValueError, "image bytes are required")
  if image.mimeType.len == 0:
    raise newException(ValueError, "image mimeType is required")

  let url = buildPredictUrl(client, model)
  let bodyJson = buildEditImageRequest(prompt, image, config)

  let resp = await client.http.request(url, HttpPost, body = $bodyJson)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseEditImagePayloadToResponse(respBody, statusCode)

proc upscaleImageInternal(client: Client, model: string, image: Image,
                          upscaleFactor: string,
                          config: UpscaleImageConfig): Future[UpscaleImageResponse]
                          {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")
  if image.bytesBase64.len == 0:
    raise newException(ValueError, "image bytes are required")
  if image.mimeType.len == 0:
    raise newException(ValueError, "image mimeType is required")
  if upscaleFactor.len == 0:
    raise newException(ValueError, "upscaleFactor is required")

  let normalizedFactor = upscaleFactor.strip().toLowerAscii()
  if normalizedFactor != "x2" and normalizedFactor != "x4":
    raise newException(ValueError, "upscaleFactor must be either x2 or x4")

  let url = buildPredictUrl(client, model)
  let bodyJson = buildUpscaleImageRequest(image, normalizedFactor, config)

  let resp = await client.http.request(url, HttpPost, body = $bodyJson)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseUpscaleImagePayloadToResponse(respBody, statusCode)

proc generateVideosInternal(client: Client, model: string,
                            prompt: string,
                            image: Option[Image],
                            video: Option[Video],
                            source: Option[GenerateVideosSource],
                            config: GenerateVideosConfig): Future[GenerateVideosOperation]
                            {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")
  if source.isSome and (prompt.len > 0 or image.isSome or video.isSome):
    raise newException(ValueError, "source and prompt/image/video are mutually exclusive")

  if source.isSome:
    validateGenerateVideosSource(source.get())
  else:
    if image.isSome:
      let imageValue = image.get()
      if imageValue.bytesBase64.len == 0:
        raise newException(ValueError, "image bytes are required")
      if imageValue.mimeType.len == 0:
        raise newException(ValueError, "image mimeType is required")
    if video.isSome:
      validateVideoInput(video.get())
    if prompt.len == 0 and not image.isSome and not video.isSome:
      raise newException(ValueError, "prompt, image, video, or source is required")

  if config.lastFrame.isSome:
    let lastFrame = config.lastFrame.get()
    if lastFrame.bytesBase64.len == 0:
      raise newException(ValueError, "config.lastFrame bytes are required")
    if lastFrame.mimeType.len == 0:
      raise newException(ValueError, "config.lastFrame mimeType is required")

  for referenceImage in config.referenceImages:
    if referenceImage.image.bytesBase64.len == 0:
      raise newException(ValueError, "reference image bytes are required")
    if referenceImage.image.mimeType.len == 0:
      raise newException(ValueError, "reference image mimeType is required")

  let url = buildPredictLongRunningUrl(client, model)
  let bodyJson = buildGenerateVideosRequest(prompt, image, video, source, config)
  let resp = await client.http.request(url, HttpPost, body = $bodyJson)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseGenerateVideosOperationPayload(respBody)

proc getOperationInternal(client: Client,
                          operationName: string): Future[GenerateVideosOperation]
                          {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if operationName.len == 0:
    raise newException(ValueError, "operationName is required")

  let url = buildOperationUrl(client, operationName)
  let resp = await client.http.request(url, HttpGet)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseGenerateVideosOperationPayload(respBody)

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

proc generateImages*(client: Client, model: string, prompt: string,
                     config: GenerateImagesConfig = GenerateImagesConfig()): Future[GenerateImagesResponse]
                     {.async.} =
  result = await generateImagesInternal(client, model, prompt, config)

proc editImage*(client: Client, model: string, prompt: string, image: Image,
                config: EditImageConfig = EditImageConfig()): Future[EditImageResponse]
                {.async.} =
  result = await editImageInternal(client, model, prompt, image, config)

proc upscaleImage*(client: Client, model: string, image: Image,
                   upscaleFactor: string,
                   config: UpscaleImageConfig = UpscaleImageConfig()): Future[UpscaleImageResponse]
                   {.async.} =
  result = await upscaleImageInternal(client, model, image, upscaleFactor, config)

proc generateVideos*(client: Client, model: string, prompt: string,
                     config: GenerateVideosConfig = GenerateVideosConfig()): Future[GenerateVideosOperation]
                     {.async.} =
  result = await generateVideosInternal(
    client = client,
    model = model,
    prompt = prompt,
    image = none(Image),
    video = none(Video),
    source = none(GenerateVideosSource),
    config = config
  )

proc generateVideos*(client: Client, model: string, source: GenerateVideosSource,
                     config: GenerateVideosConfig = GenerateVideosConfig()): Future[GenerateVideosOperation]
                     {.async.} =
  result = await generateVideosInternal(
    client = client,
    model = model,
    prompt = "",
    image = none(Image),
    video = none(Video),
    source = some(source),
    config = config
  )

proc generateVideos*(client: Client, model: string, image: Image,
                     prompt = "",
                     config: GenerateVideosConfig = GenerateVideosConfig()): Future[GenerateVideosOperation]
                     {.async.} =
  result = await generateVideosInternal(
    client = client,
    model = model,
    prompt = prompt,
    image = some(image),
    video = none(Video),
    source = none(GenerateVideosSource),
    config = config
  )

proc generateVideos*(client: Client, model: string, video: Video,
                     prompt = "",
                     config: GenerateVideosConfig = GenerateVideosConfig()): Future[GenerateVideosOperation]
                     {.async.} =
  result = await generateVideosInternal(
    client = client,
    model = model,
    prompt = prompt,
    image = none(Image),
    video = some(video),
    source = none(GenerateVideosSource),
    config = config
  )

proc getOperation*(client: Client, operationName: string): Future[GenerateVideosOperation]
                   {.async.} =
  result = await getOperationInternal(client, operationName)

proc getOperation*(client: Client, operation: GenerateVideosOperation): Future[GenerateVideosOperation]
                   {.async.} =
  result = await getOperationInternal(client, operation.name)

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
