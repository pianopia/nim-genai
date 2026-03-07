import std/[asyncdispatch, asyncstreams, httpclient, json, mimetypes, options, os, strutils, tables]

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

proc normalizeFileName(fileName: string): string =
  if fileName.len == 0:
    raise newException(ValueError, "file name is required")

  var normalized = fileName
  if normalized.startsWith("https://"):
    let marker = "files/"
    let markerIndex = normalized.find(marker)
    if markerIndex < 0:
      raise newException(ValueError, "could not extract file name from URI: " & fileName)
    let suffixStart = markerIndex + marker.len
    if suffixStart >= normalized.len:
      raise newException(ValueError, "could not extract file name from URI: " & fileName)
    let suffix = normalized[suffixStart .. ^1]
    var extracted = ""
    for c in suffix:
      if c in {'a'..'z', '0'..'9'}:
        extracted.add(c)
      else:
        break
    if extracted.len == 0:
      raise newException(ValueError, "could not extract file name from URI: " & fileName)
    normalized = extracted
  elif normalized.startsWith("files/"):
    if normalized.len <= "files/".len:
      raise newException(ValueError, "file name is required")
    normalized = normalized["files/".len .. ^1]

  if normalized.len == 0:
    raise newException(ValueError, "file name is required")
  result = normalized

proc normalizeUploadedFileName(name: string): string =
  if name.len == 0:
    raise newException(ValueError, "file name is required")
  if name.startsWith("files/"):
    return name
  result = "files/" & name

proc detectMimeType(filePath: string,
                    configuredMimeType: Option[string]): string =
  if configuredMimeType.isSome:
    let mimeType = configuredMimeType.get().strip()
    if mimeType.len == 0:
      raise newException(ValueError, "config.mimeType must not be empty")
    return mimeType

  let ext = splitFile(filePath).ext
  if ext.len > 1:
    let db = newMimetypes()
    let guessed = db.getMimetype(ext[1 .. ^1], "")
    if guessed.len > 0:
      return guessed

  result = "application/octet-stream"

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

proc buildCountTokensRequest(contents: seq[Content],
                             config: CountTokensConfig): JsonNode =
  result = newJObject()
  let contentsNode = newJArray()
  for content in contents:
    contentsNode.add(content.toJson())
  result["contents"] = contentsNode

  if config.systemInstruction.isSome:
    raise newException(
      ValueError,
      "systemInstruction in countTokens config is not supported in Gemini API."
    )
  if config.tools.len > 0:
    raise newException(
      ValueError,
      "tools in countTokens config are not supported in Gemini API."
    )
  if config.generationConfig.isSome:
    raise newException(
      ValueError,
      "generationConfig in countTokens config is not supported in Gemini API."
    )

proc buildUpdateModelRequest(config: UpdateModelConfig): JsonNode =
  result = config.toJson()

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

proc buildCountTokensUrl(client: Client, model: string): string =
  let modelPath = normalizeModelPath(model)
  let path = client.apiVersion & "/" & modelPath & ":countTokens"
  result = joinUrl(client.baseUrl, path)

proc buildGetModelUrl(client: Client, model: string): string =
  let modelPath = normalizeModelPath(model)
  let path = client.apiVersion & "/" & modelPath
  result = joinUrl(client.baseUrl, path)

proc buildUpdateModelUrl(client: Client, model: string): string =
  result = buildGetModelUrl(client, model)

proc buildDeleteModelUrl(client: Client, model: string): string =
  result = buildGetModelUrl(client, model)

proc buildListModelsUrl(client: Client, config: ListModelsConfig): string =
  var path = client.apiVersion & "/"
  let queryBase = if config.queryBase.isSome: config.queryBase.get() else: true
  if queryBase:
    path.add("models")
  else:
    path.add("tunedModels")
  result = joinUrl(client.baseUrl, path)

  var queryParams: seq[string] = @[]
  if config.pageSize.isSome:
    queryParams.add("pageSize=" & $config.pageSize.get())
  if config.pageToken.isSome:
    queryParams.add("pageToken=" & config.pageToken.get())
  if config.filter.isSome:
    queryParams.add("filter=" & config.filter.get())
  if queryParams.len > 0:
    result.add("?" & queryParams.join("&"))

proc buildGetFileUrl(client: Client, fileName: string): string =
  let normalizedFileName = normalizeFileName(fileName)
  let path = client.apiVersion & "/files/" & normalizedFileName
  result = joinUrl(client.baseUrl, path)

proc buildDeleteFileUrl(client: Client, fileName: string): string =
  result = buildGetFileUrl(client, fileName)

proc buildListFilesUrl(client: Client, config: ListFilesConfig): string =
  let path = client.apiVersion & "/files"
  result = joinUrl(client.baseUrl, path)

  var queryParams: seq[string] = @[]
  if config.pageSize.isSome:
    queryParams.add("pageSize=" & $config.pageSize.get())
  if config.pageToken.isSome:
    queryParams.add("pageToken=" & config.pageToken.get())
  if queryParams.len > 0:
    result.add("?" & queryParams.join("&"))

proc buildUploadFilesUrl(client: Client): string =
  let path = "upload/" & client.apiVersion & "/files"
  result = joinUrl(client.baseUrl, path)

proc buildDownloadFileUrl(client: Client, fileName: string): string =
  let normalizedFileName = normalizeFileName(fileName)
  let path = client.apiVersion & "/files/" & normalizedFileName & ":download?alt=media"
  result = joinUrl(client.baseUrl, path)

proc buildRegisterFilesUrl(client: Client): string =
  let path = client.apiVersion & "/files:register"
  result = joinUrl(client.baseUrl, path)

proc buildUploadFileStartRequest(fileName: string,
                                 displayName: Option[string],
                                 mimeType: string): JsonNode =
  result = newJObject()
  let fileNode = newJObject()
  fileNode["mimeType"] = %mimeType
  if fileName.len > 0:
    fileNode["name"] = %normalizeUploadedFileName(fileName)
  if displayName.isSome:
    let value = displayName.get()
    if value.len == 0:
      raise newException(ValueError, "config.displayName must not be empty")
    fileNode["displayName"] = %value
  result["file"] = fileNode

proc buildRegisterFilesRequest(uris: seq[string]): JsonNode =
  result = newJObject()
  let urisNode = newJArray()
  for uri in uris:
    urisNode.add(%uri)
  result["uris"] = urisNode

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

proc parseGetModelPayloadToResponse(payload: string, fallbackCode: int): Model =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = extractModel(raw)

proc parseListModelsPayloadToResponse(payload: string, fallbackCode: int): ListModelsResponse =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = ListModelsResponse(
    raw: raw,
    nextPageToken: extractListModelsNextPageToken(raw),
    models: extractModels(raw)
  )

proc parseCountTokensPayloadToResponse(payload: string, fallbackCode: int): CountTokensResponse =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = extractCountTokensResponse(raw)

proc parseDeleteModelPayloadToResponse(payload: string, fallbackCode: int): DeleteModelResponse =
  var raw: JsonNode
  if payload.strip().len == 0:
    raw = newJObject()
  else:
    raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = DeleteModelResponse(raw: raw)

proc parseGetFilePayloadToResponse(payload: string, fallbackCode: int): FileResource =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = extractFileResource(raw)

proc parseListFilesPayloadToResponse(payload: string, fallbackCode: int): ListFilesResponse =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = ListFilesResponse(
    raw: raw,
    nextPageToken: extractListFilesNextPageToken(raw),
    files: extractFiles(raw)
  )

proc parseDeleteFilePayloadToResponse(payload: string, fallbackCode: int): DeleteFileResponse =
  var raw: JsonNode
  if payload.strip().len == 0:
    raw = newJObject()
  else:
    raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = DeleteFileResponse(raw: raw)

proc parseUploadFilePayloadToResponse(payload: string,
                                      fallbackCode: int): FileResource =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  if raw.kind == JObject and raw.hasKey("file") and raw["file"].kind == JObject:
    return extractFileResource(raw["file"])
  result = extractFileResource(raw)

proc parseRegisterFilesPayloadToResponse(payload: string,
                                         fallbackCode: int): RegisterFilesResponse =
  let raw = parseJson(payload)
  if raw.kind == JObject and raw.hasKey("error"):
    raise newGenAIError(extractErrorCode(raw, fallbackCode), payload)
  result = RegisterFilesResponse(
    raw: raw,
    files: extractFiles(raw)
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

proc countTokensInternal(client: Client, model: string, contents: seq[Content],
                         config: CountTokensConfig): Future[CountTokensResponse]
                         {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")
  if contents.len == 0:
    raise newException(ValueError, "contents is required")

  let url = buildCountTokensUrl(client, model)
  let bodyJson = buildCountTokensRequest(contents, config)
  let resp = await client.http.request(url, HttpPost, body = $bodyJson)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseCountTokensPayloadToResponse(respBody, statusCode)

proc getModelInternal(client: Client, model: string): Future[Model]
                      {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")

  let url = buildGetModelUrl(client, model)
  let resp = await client.http.request(url, HttpGet)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseGetModelPayloadToResponse(respBody, statusCode)

proc listModelsInternal(client: Client,
                        config: ListModelsConfig): Future[ListModelsResponse]
                        {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")

  let url = buildListModelsUrl(client, config)
  let resp = await client.http.request(url, HttpGet)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseListModelsPayloadToResponse(respBody, statusCode)

proc updateModelInternal(client: Client, model: string,
                         config: UpdateModelConfig): Future[Model]
                         {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")

  let url = buildUpdateModelUrl(client, model)
  let bodyJson = buildUpdateModelRequest(config)
  let resp = await client.http.request(url, HttpPatch, body = $bodyJson)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseGetModelPayloadToResponse(respBody, statusCode)

proc deleteModelInternal(client: Client, model: string): Future[DeleteModelResponse]
                         {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")

  let url = buildDeleteModelUrl(client, model)
  let resp = await client.http.request(url, HttpDelete)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseDeleteModelPayloadToResponse(respBody, statusCode)

proc getFileInternal(client: Client, fileName: string): Future[FileResource]
                     {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if fileName.len == 0:
    raise newException(ValueError, "file name is required")

  let url = buildGetFileUrl(client, fileName)
  let resp = await client.http.request(url, HttpGet)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseGetFilePayloadToResponse(respBody, statusCode)

proc listFilesInternal(client: Client, config: ListFilesConfig): Future[ListFilesResponse]
                       {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")

  let url = buildListFilesUrl(client, config)
  let resp = await client.http.request(url, HttpGet)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseListFilesPayloadToResponse(respBody, statusCode)

proc deleteFileInternal(client: Client, fileName: string): Future[DeleteFileResponse]
                        {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if fileName.len == 0:
    raise newException(ValueError, "file name is required")

  let url = buildDeleteFileUrl(client, fileName)
  let resp = await client.http.request(url, HttpDelete)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseDeleteFilePayloadToResponse(respBody, statusCode)

proc uploadFileInternal(client: Client, filePath: string,
                        config: UploadFileConfig): Future[FileResource]
                        {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if filePath.len == 0:
    raise newException(ValueError, "filePath is required")
  if not fileExists(filePath):
    raise newException(IOError, filePath & " is not a valid file path")

  let mimeType = detectMimeType(filePath, config.mimeType)
  let fileBytes = readFile(filePath)
  let uploadSize = fileBytes.len

  let startUrl = buildUploadFilesUrl(client)
  var startHeaders = newHttpHeaders()
  startHeaders["Content-Type"] = "application/json"
  startHeaders["X-Goog-Upload-Protocol"] = "resumable"
  startHeaders["X-Goog-Upload-Command"] = "start"
  startHeaders["X-Goog-Upload-Header-Content-Length"] = $uploadSize
  startHeaders["X-Goog-Upload-Header-Content-Type"] = mimeType
  startHeaders["X-Goog-Upload-File-Name"] = extractFilename(filePath)

  let startBodyJson = buildUploadFileStartRequest(
    fileName = if config.name.isSome: config.name.get() else: "",
    displayName = config.displayName,
    mimeType = mimeType
  )

  let startResp = await client.http.request(
    startUrl,
    HttpPost,
    body = $startBodyJson,
    headers = startHeaders
  )
  let startStatusCode = startResp.code.int
  let startRespBody = await startResp.body()
  if startStatusCode < 200 or startStatusCode >= 300:
    raise newGenAIError(startStatusCode, startRespBody)

  var uploadUrl = ""
  if startResp.headers.hasKey("x-goog-upload-url"):
    uploadUrl = startResp.headers["x-goog-upload-url"]
  if uploadUrl.len == 0 and startResp.headers.hasKey("X-Goog-Upload-URL"):
    uploadUrl = startResp.headers["X-Goog-Upload-URL"]
  if uploadUrl.len == 0:
    raise newException(
      KeyError,
      "Failed to create file. Upload URL did not return from the create file request."
    )

  var uploadHeaders = newHttpHeaders()
  uploadHeaders["X-Goog-Upload-Command"] = "upload, finalize"
  uploadHeaders["X-Goog-Upload-Offset"] = "0"
  uploadHeaders["Content-Length"] = $uploadSize
  uploadHeaders["Content-Type"] = mimeType
  let uploadResp = await client.http.request(
    uploadUrl,
    HttpPost,
    body = fileBytes,
    headers = uploadHeaders
  )
  let uploadStatusCode = uploadResp.code.int
  let uploadRespBody = await uploadResp.body()
  if uploadStatusCode < 200 or uploadStatusCode >= 300:
    raise newGenAIError(uploadStatusCode, uploadRespBody)

  if uploadResp.headers.hasKey("x-goog-upload-status"):
    let uploadStatus = ($uploadResp.headers["x-goog-upload-status"]).toLowerAscii()
    if uploadStatus != "final":
      raise newException(ValueError, "Failed to upload file: Upload status is not finalized.")
  elif uploadResp.headers.hasKey("X-Goog-Upload-Status"):
    let uploadStatus = ($uploadResp.headers["X-Goog-Upload-Status"]).toLowerAscii()
    if uploadStatus != "final":
      raise newException(ValueError, "Failed to upload file: Upload status is not finalized.")

  result = parseUploadFilePayloadToResponse(uploadRespBody, uploadStatusCode)

proc downloadFileInternal(client: Client, fileName: string): Future[string]
                          {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if fileName.len == 0:
    raise newException(ValueError, "file name is required")

  let url = buildDownloadFileUrl(client, fileName)
  let resp = await client.http.request(url, HttpGet)
  let statusCode = resp.code.int
  let respBody = await resp.body()
  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)
  result = respBody

proc registerFilesInternal(client: Client, uris: seq[string],
                           config: RegisterFilesConfig): Future[RegisterFilesResponse]
                           {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if uris.len == 0:
    raise newException(ValueError, "uris is required")

  var normalizedUris: seq[string] = @[]
  for uri in uris:
    let normalized = uri.strip()
    if normalized.len == 0:
      raise newException(ValueError, "uris must not contain empty values")
    if not normalized.startsWith("gs://"):
      raise newException(ValueError, "uris must be Google Cloud Storage URIs (gs://...)")
    normalizedUris.add(normalized)

  if not config.accessToken.isSome:
    raise newException(ValueError, "config.accessToken is required")
  let token = config.accessToken.get().strip()
  if token.len == 0:
    raise newException(ValueError, "config.accessToken is required")

  let url = buildRegisterFilesUrl(client)
  let bodyJson = buildRegisterFilesRequest(normalizedUris)

  var headers = newHttpHeaders()
  headers["Content-Type"] = "application/json"
  headers["Authorization"] = "Bearer " & token
  if config.userProject.isSome:
    let userProject = config.userProject.get().strip()
    if userProject.len == 0:
      raise newException(ValueError, "config.userProject must not be empty")
    headers["x-goog-user-project"] = userProject

  let resp = await client.http.request(url, HttpPost, body = $bodyJson, headers = headers)
  let statusCode = resp.code.int
  let respBody = await resp.body()
  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  result = parseRegisterFilesPayloadToResponse(respBody, statusCode)

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

proc countTokens*(client: Client, model: string, contents: seq[Content],
                  config: CountTokensConfig = CountTokensConfig()): Future[CountTokensResponse]
                  {.async.} =
  result = await countTokensInternal(client, model, contents, config)

proc countTokens*(client: Client, model: string, content: Content,
                  config: CountTokensConfig = CountTokensConfig()): Future[CountTokensResponse]
                  {.async.} =
  result = await countTokensInternal(client, model, @[content], config)

proc countTokens*(client: Client, model: string, text: string,
                  config: CountTokensConfig = CountTokensConfig()): Future[CountTokensResponse]
                  {.async.} =
  result = await countTokensInternal(client, model, @[contentFromText(text)], config)

proc countTokens*(client: Client, model: string, texts: seq[string],
                  config: CountTokensConfig = CountTokensConfig()): Future[CountTokensResponse]
                  {.async.} =
  var contents: seq[Content] = @[]
  for text in texts:
    contents.add(contentFromText(text))
  result = await countTokensInternal(client, model, contents, config)

proc getModel*(client: Client, model: string): Future[Model]
               {.async.} =
  result = await getModelInternal(client, model)

proc listModels*(client: Client,
                 config: ListModelsConfig = ListModelsConfig()): Future[ListModelsResponse]
                 {.async.} =
  result = await listModelsInternal(client, config)

proc updateModel*(client: Client, model: string,
                  config: UpdateModelConfig): Future[Model]
                  {.async.} =
  result = await updateModelInternal(client, model, config)

proc deleteModel*(client: Client, model: string): Future[DeleteModelResponse]
                  {.async.} =
  result = await deleteModelInternal(client, model)

proc getFile*(client: Client, fileName: string): Future[FileResource]
              {.async.} =
  result = await getFileInternal(client, fileName)

proc listFiles*(client: Client,
                config: ListFilesConfig = ListFilesConfig()): Future[ListFilesResponse]
                {.async.} =
  result = await listFilesInternal(client, config)

proc deleteFile*(client: Client, fileName: string): Future[DeleteFileResponse]
                 {.async.} =
  result = await deleteFileInternal(client, fileName)

proc uploadFile*(client: Client, filePath: string,
                 config: UploadFileConfig = UploadFileConfig()): Future[FileResource]
                 {.async.} =
  result = await uploadFileInternal(client, filePath, config)

proc downloadFile*(client: Client, fileName: string): Future[string]
                   {.async.} =
  result = await downloadFileInternal(client, fileName)

proc registerFiles*(client: Client, uris: seq[string],
                    config: RegisterFilesConfig = RegisterFilesConfig()):
                    Future[RegisterFilesResponse]
                    {.async.} =
  result = await registerFilesInternal(client, uris, config)

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
