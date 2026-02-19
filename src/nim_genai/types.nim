import std/[base64, json, options, strutils]

type
  PartKind* = enum
    pkText,
    pkInlineData,
    pkFileData,
    pkFunctionCall,
    pkFunctionResponse

  InlineData* = object
    mimeType*: string
    data*: string

  FileData* = object
    mimeType*: string
    fileUri*: string

  FunctionCall* = object
    name*: string
    args*: JsonNode

  FunctionResponse* = object
    name*: string
    response*: JsonNode

  FunctionDeclaration* = object
    name*: string
    description*: string
    parameters*: JsonNode

  Tool* = object
    functionDeclarations*: seq[FunctionDeclaration]

  FunctionCallingMode* = enum
    fcmAuto,
    fcmAny,
    fcmNone

  FunctionCallingConfig* = object
    mode*: Option[FunctionCallingMode]
    allowedFunctionNames*: seq[string]

  ToolConfig* = object
    functionCallingConfig*: Option[FunctionCallingConfig]

  AutomaticFunctionCallingConfig* = object
    disable*: Option[bool]
    maximumRemoteCalls*: Option[int]
    ignoreCallHistory*: Option[bool]

  Part* = object
    case kind*: PartKind
    of pkText:
      text*: string
    of pkInlineData:
      inlineData*: InlineData
    of pkFileData:
      fileData*: FileData
    of pkFunctionCall:
      functionCall*: FunctionCall
    of pkFunctionResponse:
      functionResponse*: FunctionResponse

  Content* = object
    role*: string
    parts*: seq[Part]

  GenerateContentConfig* = object
    temperature*: Option[float]
    topP*: Option[float]
    topK*: Option[int]
    candidateCount*: Option[int]
    maxOutputTokens*: Option[int]
    stopSequences*: seq[string]
    tools*: seq[Tool]
    toolConfig*: Option[ToolConfig]
    automaticFunctionCalling*: Option[AutomaticFunctionCallingConfig]

  GenerateContentResponse* = object
    raw*: JsonNode
    text*: string
    functionCalls*: seq[FunctionCall]
    automaticFunctionCallingHistory*: seq[Content]

  EmbedContentConfig* = object
    taskType*: Option[string]
    title*: Option[string]
    outputDimensionality*: Option[int]

  ContentEmbeddingStatistics* = object
    truncated*: Option[bool]
    tokenCount*: Option[float]

  ContentEmbedding* = object
    values*: seq[float]
    statistics*: Option[ContentEmbeddingStatistics]

  EmbedContentMetadata* = object
    billableCharacterCount*: Option[int]

  EmbedContentResponse* = object
    raw*: JsonNode
    embeddings*: seq[ContentEmbedding]
    metadata*: Option[EmbedContentMetadata]

  Image* = object
    mimeType*: string
    bytesBase64*: string

  SafetyAttributes* = object
    categories*: seq[string]
    scores*: seq[float]
    contentType*: Option[string]

  GeneratedImage* = object
    image*: Option[Image]
    raiFilteredReason*: Option[string]
    safetyAttributes*: Option[SafetyAttributes]

  GenerateImagesConfig* = object
    numberOfImages*: Option[int]
    aspectRatio*: Option[string]
    guidanceScale*: Option[float]
    safetyFilterLevel*: Option[string]
    personGeneration*: Option[string]
    includeSafetyAttributes*: Option[bool]
    includeRaiReason*: Option[bool]
    language*: Option[string]
    outputMimeType*: Option[string]
    outputCompressionQuality*: Option[int]
    imageSize*: Option[string]

  EditImageConfig* = object
    numberOfImages*: Option[int]
    aspectRatio*: Option[string]
    guidanceScale*: Option[float]
    safetyFilterLevel*: Option[string]
    personGeneration*: Option[string]
    includeSafetyAttributes*: Option[bool]
    includeRaiReason*: Option[bool]
    language*: Option[string]
    outputMimeType*: Option[string]
    outputCompressionQuality*: Option[int]
    editMode*: Option[string]
    baseSteps*: Option[int]

  UpscaleImageConfig* = object
    safetyFilterLevel*: Option[string]
    personGeneration*: Option[string]
    includeRaiReason*: Option[bool]
    outputMimeType*: Option[string]
    outputCompressionQuality*: Option[int]
    enhanceInputImage*: Option[bool]
    imagePreservationFactor*: Option[float]

  GenerateImagesResponse* = object
    raw*: JsonNode
    generatedImages*: seq[GeneratedImage]
    positivePromptSafetyAttributes*: Option[SafetyAttributes]

  EditImageResponse* = object
    raw*: JsonNode
    generatedImages*: seq[GeneratedImage]

  UpscaleImageResponse* = object
    raw*: JsonNode
    generatedImages*: seq[GeneratedImage]

  Video* = object
    uri*: Option[string]
    bytesBase64*: Option[string]
    mimeType*: Option[string]

  GenerateVideosSource* = object
    prompt*: Option[string]
    image*: Option[Image]
    video*: Option[Video]

  VideoGenerationReferenceImage* = object
    image*: Image
    referenceType*: Option[string]

  GenerateVideosConfig* = object
    numberOfVideos*: Option[int]
    durationSeconds*: Option[int]
    aspectRatio*: Option[string]
    resolution*: Option[string]
    personGeneration*: Option[string]
    negativePrompt*: Option[string]
    enhancePrompt*: Option[bool]
    lastFrame*: Option[Image]
    referenceImages*: seq[VideoGenerationReferenceImage]

  GeneratedVideo* = object
    video*: Option[Video]

  GenerateVideosResponse* = object
    generatedVideos*: seq[GeneratedVideo]
    raiMediaFilteredCount*: Option[int]
    raiMediaFilteredReasons*: seq[string]

  GenerateVideosOperation* = object
    raw*: JsonNode
    name*: string
    done*: Option[bool]
    metadata*: JsonNode
    error*: JsonNode
    response*: Option[GenerateVideosResponse]
    result*: Option[GenerateVideosResponse]

proc partFromText*(text: string): Part =
  Part(kind: pkText, text: text)

proc partFromInlineData*(mimeType: string, dataBase64: string): Part =
  if mimeType.len == 0:
    raise newException(ValueError, "mimeType is required for inline data")
  if dataBase64.len == 0:
    raise newException(ValueError, "dataBase64 is required for inline data")
  Part(
    kind: pkInlineData,
    inlineData: InlineData(mimeType: mimeType, data: dataBase64)
  )

proc partFromBytes*(data: openArray[byte], mimeType: string): Part =
  result = partFromInlineData(mimeType, encode(data))

proc partFromBytes*(data: string, mimeType: string): Part =
  result = partFromInlineData(mimeType, encode(data))

proc partFromFileUri*(fileUri: string, mimeType: string): Part =
  if fileUri.len == 0:
    raise newException(ValueError, "fileUri is required for file data")
  if mimeType.len == 0:
    raise newException(ValueError, "mimeType is required for file data")
  Part(
    kind: pkFileData,
    fileData: FileData(fileUri: fileUri, mimeType: mimeType)
  )

proc partFromUri*(fileUri: string, mimeType: string): Part =
  ## Alias for compatibility with other SDK naming.
  result = partFromFileUri(fileUri, mimeType)

proc partFromFunctionCall*(name: string, args: JsonNode = nil): Part =
  if name.len == 0:
    raise newException(ValueError, "name is required for function call")
  var normalizedArgs = args
  if normalizedArgs.isNil:
    normalizedArgs = newJObject()
  Part(
    kind: pkFunctionCall,
    functionCall: FunctionCall(name: name, args: normalizedArgs)
  )

proc partFromFunctionResponse*(name: string, response: JsonNode = nil): Part =
  if name.len == 0:
    raise newException(ValueError, "name is required for function response")
  var normalizedResponse = response
  if normalizedResponse.isNil:
    normalizedResponse = newJObject()
  Part(
    kind: pkFunctionResponse,
    functionResponse: FunctionResponse(name: name, response: normalizedResponse)
  )

proc contentFromText*(text: string; role = "user"): Content =
  Content(role: role, parts: @[partFromText(text)])

proc contentFromParts*(parts: seq[Part]; role = "user"): Content =
  Content(role: role, parts: parts)

proc contentFromFunctionResponse*(name: string, response: JsonNode,
                                  role = "tool"): Content =
  Content(role: role, parts: @[partFromFunctionResponse(name, response)])

proc systemInstructionFromText*(text: string): Content =
  Content(role: "system", parts: @[partFromText(text)])

proc functionDeclaration*(name: string, description = "",
                          parameters: JsonNode = nil): FunctionDeclaration =
  if name.len == 0:
    raise newException(ValueError, "function declaration name is required")
  result = FunctionDeclaration(name: name, description: description)
  if parameters.isNil:
    result.parameters = newJObject()
  else:
    result.parameters = parameters

proc toolFromFunctions*(functionDeclarations: seq[FunctionDeclaration]): Tool =
  if functionDeclarations.len == 0:
    raise newException(ValueError, "at least one function declaration is required")
  Tool(functionDeclarations: functionDeclarations)

proc functionCallingConfig*(mode: FunctionCallingMode,
                            allowedFunctionNames: seq[string] = @[]): FunctionCallingConfig =
  FunctionCallingConfig(mode: some(mode), allowedFunctionNames: allowedFunctionNames)

proc toolConfig*(functionCallingConfig: FunctionCallingConfig): ToolConfig =
  ToolConfig(functionCallingConfig: some(functionCallingConfig))

proc automaticFunctionCallingConfig*(disable = none(bool),
                                     maximumRemoteCalls = none(int),
                                     ignoreCallHistory = none(bool)): AutomaticFunctionCallingConfig =
  AutomaticFunctionCallingConfig(
    disable: disable,
    maximumRemoteCalls: maximumRemoteCalls,
    ignoreCallHistory: ignoreCallHistory
  )

proc embedContentConfig*(taskType = none(string), title = none(string),
                         outputDimensionality = none(int)): EmbedContentConfig =
  EmbedContentConfig(
    taskType: taskType,
    title: title,
    outputDimensionality: outputDimensionality
  )

proc imageFromBase64*(mimeType: string, dataBase64: string): Image =
  if mimeType.len == 0:
    raise newException(ValueError, "mimeType is required for image input")
  if dataBase64.len == 0:
    raise newException(ValueError, "dataBase64 is required for image input")
  Image(mimeType: mimeType, bytesBase64: dataBase64)

proc imageFromBytes*(data: openArray[byte], mimeType: string): Image =
  result = imageFromBase64(mimeType, encode(data))

proc imageFromBytes*(data: string, mimeType: string): Image =
  result = imageFromBase64(mimeType, encode(data))

proc generateImagesConfig*(numberOfImages = none(int),
                           aspectRatio = none(string),
                           guidanceScale = none(float),
                           safetyFilterLevel = none(string),
                           personGeneration = none(string),
                           includeSafetyAttributes = none(bool),
                           includeRaiReason = none(bool),
                           language = none(string),
                           outputMimeType = none(string),
                           outputCompressionQuality = none(int),
                           imageSize = none(string)): GenerateImagesConfig =
  GenerateImagesConfig(
    numberOfImages: numberOfImages,
    aspectRatio: aspectRatio,
    guidanceScale: guidanceScale,
    safetyFilterLevel: safetyFilterLevel,
    personGeneration: personGeneration,
    includeSafetyAttributes: includeSafetyAttributes,
    includeRaiReason: includeRaiReason,
    language: language,
    outputMimeType: outputMimeType,
    outputCompressionQuality: outputCompressionQuality,
    imageSize: imageSize
  )

proc editImageConfig*(numberOfImages = none(int),
                      aspectRatio = none(string),
                      guidanceScale = none(float),
                      safetyFilterLevel = none(string),
                      personGeneration = none(string),
                      includeSafetyAttributes = none(bool),
                      includeRaiReason = none(bool),
                      language = none(string),
                      outputMimeType = none(string),
                      outputCompressionQuality = none(int),
                      editMode = none(string),
                      baseSteps = none(int)): EditImageConfig =
  EditImageConfig(
    numberOfImages: numberOfImages,
    aspectRatio: aspectRatio,
    guidanceScale: guidanceScale,
    safetyFilterLevel: safetyFilterLevel,
    personGeneration: personGeneration,
    includeSafetyAttributes: includeSafetyAttributes,
    includeRaiReason: includeRaiReason,
    language: language,
    outputMimeType: outputMimeType,
    outputCompressionQuality: outputCompressionQuality,
    editMode: editMode,
    baseSteps: baseSteps
  )

proc upscaleImageConfig*(safetyFilterLevel = none(string),
                         personGeneration = none(string),
                         includeRaiReason = none(bool),
                         outputMimeType = none(string),
                         outputCompressionQuality = none(int),
                         enhanceInputImage = none(bool),
                         imagePreservationFactor = none(float)): UpscaleImageConfig =
  UpscaleImageConfig(
    safetyFilterLevel: safetyFilterLevel,
    personGeneration: personGeneration,
    includeRaiReason: includeRaiReason,
    outputMimeType: outputMimeType,
    outputCompressionQuality: outputCompressionQuality,
    enhanceInputImage: enhanceInputImage,
    imagePreservationFactor: imagePreservationFactor
  )

proc videoFromUri*(uri: string, mimeType = none(string)): Video =
  if uri.len == 0:
    raise newException(ValueError, "uri is required for video input")
  result = Video(uri: some(uri))
  if mimeType.isSome:
    if mimeType.get().len == 0:
      raise newException(ValueError, "mimeType must not be empty when provided")
    result.mimeType = some(mimeType.get())

proc videoFromBase64*(mimeType: string, dataBase64: string): Video =
  if mimeType.len == 0:
    raise newException(ValueError, "mimeType is required for video input")
  if dataBase64.len == 0:
    raise newException(ValueError, "dataBase64 is required for video input")
  Video(bytesBase64: some(dataBase64), mimeType: some(mimeType))

proc videoFromBytes*(data: openArray[byte], mimeType: string): Video =
  result = videoFromBase64(mimeType, encode(data))

proc videoFromBytes*(data: string, mimeType: string): Video =
  result = videoFromBase64(mimeType, encode(data))

proc generateVideosSource*(prompt = none(string),
                           image = none(Image),
                           video = none(Video)): GenerateVideosSource =
  GenerateVideosSource(
    prompt: prompt,
    image: image,
    video: video
  )

proc videoGenerationReferenceImage*(image: Image,
                                    referenceType = none(string)): VideoGenerationReferenceImage =
  VideoGenerationReferenceImage(
    image: image,
    referenceType: referenceType
  )

proc generateVideosConfig*(numberOfVideos = none(int),
                           durationSeconds = none(int),
                           aspectRatio = none(string),
                           resolution = none(string),
                           personGeneration = none(string),
                           negativePrompt = none(string),
                           enhancePrompt = none(bool),
                           lastFrame = none(Image),
                           referenceImages: seq[VideoGenerationReferenceImage] = @[]): GenerateVideosConfig =
  GenerateVideosConfig(
    numberOfVideos: numberOfVideos,
    durationSeconds: durationSeconds,
    aspectRatio: aspectRatio,
    resolution: resolution,
    personGeneration: personGeneration,
    negativePrompt: negativePrompt,
    enhancePrompt: enhancePrompt,
    lastFrame: lastFrame,
    referenceImages: referenceImages
  )

proc toJson*(functionCall: FunctionCall): JsonNode =
  result = newJObject()
  result["name"] = %functionCall.name
  if functionCall.args.isNil:
    result["args"] = newJObject()
  else:
    result["args"] = functionCall.args

proc toJson*(functionResponse: FunctionResponse): JsonNode =
  result = newJObject()
  result["name"] = %functionResponse.name
  if functionResponse.response.isNil:
    result["response"] = newJObject()
  else:
    result["response"] = functionResponse.response

proc toJson*(functionDeclaration: FunctionDeclaration): JsonNode =
  result = newJObject()
  result["name"] = %functionDeclaration.name
  if functionDeclaration.description.len > 0:
    result["description"] = %functionDeclaration.description
  if functionDeclaration.parameters.isNil:
    result["parameters"] = newJObject()
  else:
    result["parameters"] = functionDeclaration.parameters

proc toJson*(tool: Tool): JsonNode =
  result = newJObject()
  let declarationsNode = newJArray()
  for declaration in tool.functionDeclarations:
    declarationsNode.add(declaration.toJson())
  result["functionDeclarations"] = declarationsNode

proc toJson(mode: FunctionCallingMode): JsonNode =
  case mode
  of fcmAuto:
    %"AUTO"
  of fcmAny:
    %"ANY"
  of fcmNone:
    %"NONE"

proc toJson*(functionCallingConfig: FunctionCallingConfig): JsonNode =
  result = newJObject()
  if functionCallingConfig.mode.isSome:
    result["mode"] = functionCallingConfig.mode.get().toJson()
  if functionCallingConfig.allowedFunctionNames.len > 0:
    result["allowedFunctionNames"] = %functionCallingConfig.allowedFunctionNames

proc toJson*(toolConfig: ToolConfig): JsonNode =
  result = newJObject()
  if toolConfig.functionCallingConfig.isSome:
    result["functionCallingConfig"] = toolConfig.functionCallingConfig.get().toJson()

proc toJson*(automaticFunctionCallingConfig: AutomaticFunctionCallingConfig): JsonNode =
  result = newJObject()
  if automaticFunctionCallingConfig.disable.isSome:
    result["disable"] = %automaticFunctionCallingConfig.disable.get()
  if automaticFunctionCallingConfig.maximumRemoteCalls.isSome:
    result["maximumRemoteCalls"] = %automaticFunctionCallingConfig.maximumRemoteCalls.get()
  if automaticFunctionCallingConfig.ignoreCallHistory.isSome:
    result["ignoreCallHistory"] = %automaticFunctionCallingConfig.ignoreCallHistory.get()

proc toJson*(config: EmbedContentConfig): JsonNode =
  result = newJObject()
  if config.taskType.isSome:
    result["taskType"] = %config.taskType.get()
  if config.title.isSome:
    result["title"] = %config.title.get()
  if config.outputDimensionality.isSome:
    result["outputDimensionality"] = %config.outputDimensionality.get()

proc toJson*(image: Image): JsonNode =
  result = newJObject()
  result["bytesBase64Encoded"] = %image.bytesBase64
  result["mimeType"] = %image.mimeType

proc toJson*(video: Video): JsonNode =
  result = newJObject()
  if video.uri.isSome:
    result["uri"] = %video.uri.get()
  if video.bytesBase64.isSome:
    result["encodedVideo"] = %video.bytesBase64.get()
  if video.mimeType.isSome:
    result["encoding"] = %video.mimeType.get()

proc toJson*(config: GenerateImagesConfig): JsonNode =
  result = newJObject()
  if config.numberOfImages.isSome:
    result["sampleCount"] = %config.numberOfImages.get()
  if config.aspectRatio.isSome:
    result["aspectRatio"] = %config.aspectRatio.get()
  if config.guidanceScale.isSome:
    result["guidanceScale"] = %config.guidanceScale.get()
  if config.safetyFilterLevel.isSome:
    result["safetySetting"] = %config.safetyFilterLevel.get()
  if config.personGeneration.isSome:
    result["personGeneration"] = %config.personGeneration.get()
  if config.includeSafetyAttributes.isSome:
    result["includeSafetyAttributes"] = %config.includeSafetyAttributes.get()
  if config.includeRaiReason.isSome:
    result["includeRaiReason"] = %config.includeRaiReason.get()
  if config.language.isSome:
    result["language"] = %config.language.get()
  if config.imageSize.isSome:
    result["sampleImageSize"] = %config.imageSize.get()
  if config.outputMimeType.isSome or config.outputCompressionQuality.isSome:
    var outputOptions = newJObject()
    if config.outputMimeType.isSome:
      outputOptions["mimeType"] = %config.outputMimeType.get()
    if config.outputCompressionQuality.isSome:
      outputOptions["compressionQuality"] = %config.outputCompressionQuality.get()
    result["outputOptions"] = outputOptions

proc toJson*(config: EditImageConfig): JsonNode =
  result = newJObject()
  if config.numberOfImages.isSome:
    result["sampleCount"] = %config.numberOfImages.get()
  if config.aspectRatio.isSome:
    result["aspectRatio"] = %config.aspectRatio.get()
  if config.guidanceScale.isSome:
    result["guidanceScale"] = %config.guidanceScale.get()
  if config.safetyFilterLevel.isSome:
    result["safetySetting"] = %config.safetyFilterLevel.get()
  if config.personGeneration.isSome:
    result["personGeneration"] = %config.personGeneration.get()
  if config.includeSafetyAttributes.isSome:
    result["includeSafetyAttributes"] = %config.includeSafetyAttributes.get()
  if config.includeRaiReason.isSome:
    result["includeRaiReason"] = %config.includeRaiReason.get()
  if config.language.isSome:
    result["language"] = %config.language.get()
  if config.editMode.isSome:
    result["editMode"] = %config.editMode.get()
  if config.baseSteps.isSome:
    var editConfigNode = newJObject()
    editConfigNode["baseSteps"] = %config.baseSteps.get()
    result["editConfig"] = editConfigNode
  if config.outputMimeType.isSome or config.outputCompressionQuality.isSome:
    var outputOptions = newJObject()
    if config.outputMimeType.isSome:
      outputOptions["mimeType"] = %config.outputMimeType.get()
    if config.outputCompressionQuality.isSome:
      outputOptions["compressionQuality"] = %config.outputCompressionQuality.get()
    result["outputOptions"] = outputOptions

proc toJson*(config: UpscaleImageConfig): JsonNode =
  result = newJObject()
  if config.safetyFilterLevel.isSome:
    result["safetySetting"] = %config.safetyFilterLevel.get()
  if config.personGeneration.isSome:
    result["personGeneration"] = %config.personGeneration.get()
  if config.includeRaiReason.isSome:
    result["includeRaiReason"] = %config.includeRaiReason.get()
  if config.enhanceInputImage.isSome or config.imagePreservationFactor.isSome:
    var upscaleConfigNode = newJObject()
    if config.enhanceInputImage.isSome:
      upscaleConfigNode["enhanceInputImage"] = %config.enhanceInputImage.get()
    if config.imagePreservationFactor.isSome:
      upscaleConfigNode["imagePreservationFactor"] = %config.imagePreservationFactor.get()
    result["upscaleConfig"] = upscaleConfigNode
  if config.outputMimeType.isSome or config.outputCompressionQuality.isSome:
    var outputOptions = newJObject()
    if config.outputMimeType.isSome:
      outputOptions["mimeType"] = %config.outputMimeType.get()
    if config.outputCompressionQuality.isSome:
      outputOptions["compressionQuality"] = %config.outputCompressionQuality.get()
    result["outputOptions"] = outputOptions

proc toJson*(source: GenerateVideosSource): JsonNode =
  result = newJObject()
  if source.prompt.isSome:
    result["prompt"] = %source.prompt.get()
  if source.image.isSome:
    result["image"] = source.image.get().toJson()
  if source.video.isSome:
    result["video"] = source.video.get().toJson()

proc toJson*(referenceImage: VideoGenerationReferenceImage): JsonNode =
  result = newJObject()
  result["image"] = referenceImage.image.toJson()
  if referenceImage.referenceType.isSome:
    result["referenceType"] = %referenceImage.referenceType.get()

proc toJson*(config: GenerateVideosConfig): JsonNode =
  result = newJObject()
  if config.numberOfVideos.isSome:
    result["sampleCount"] = %config.numberOfVideos.get()
  if config.durationSeconds.isSome:
    result["durationSeconds"] = %config.durationSeconds.get()
  if config.aspectRatio.isSome:
    result["aspectRatio"] = %config.aspectRatio.get()
  if config.resolution.isSome:
    result["resolution"] = %config.resolution.get()
  if config.personGeneration.isSome:
    result["personGeneration"] = %config.personGeneration.get()
  if config.negativePrompt.isSome:
    result["negativePrompt"] = %config.negativePrompt.get()
  if config.enhancePrompt.isSome:
    result["enhancePrompt"] = %config.enhancePrompt.get()

proc toJson*(part: Part): JsonNode =
  result = newJObject()
  case part.kind
  of pkText:
    result["text"] = %part.text
  of pkInlineData:
    let inlineNode = newJObject()
    inlineNode["mimeType"] = %part.inlineData.mimeType
    inlineNode["data"] = %part.inlineData.data
    result["inlineData"] = inlineNode
  of pkFileData:
    let fileNode = newJObject()
    fileNode["mimeType"] = %part.fileData.mimeType
    fileNode["fileUri"] = %part.fileData.fileUri
    result["fileData"] = fileNode
  of pkFunctionCall:
    result["functionCall"] = part.functionCall.toJson()
  of pkFunctionResponse:
    result["functionResponse"] = part.functionResponse.toJson()

proc toJson*(content: Content): JsonNode =
  result = newJObject()
  if content.role.len > 0:
    result["role"] = %content.role
  let partsNode = newJArray()
  for part in content.parts:
    partsNode.add(part.toJson())
  result["parts"] = partsNode

proc toJson*(config: GenerateContentConfig): JsonNode =
  result = newJObject()
  if config.temperature.isSome:
    result["temperature"] = %config.temperature.get()
  if config.topP.isSome:
    result["topP"] = %config.topP.get()
  if config.topK.isSome:
    result["topK"] = %config.topK.get()
  if config.candidateCount.isSome:
    result["candidateCount"] = %config.candidateCount.get()
  if config.maxOutputTokens.isSome:
    result["maxOutputTokens"] = %config.maxOutputTokens.get()
  if config.stopSequences.len > 0:
    result["stopSequences"] = %config.stopSequences
  if config.tools.len > 0:
    let toolsNode = newJArray()
    for tool in config.tools:
      toolsNode.add(tool.toJson())
    result["tools"] = toolsNode
  if config.toolConfig.isSome:
    result["toolConfig"] = config.toolConfig.get().toJson()
  if config.automaticFunctionCalling.isSome:
    result["automaticFunctionCalling"] = config.automaticFunctionCalling.get().toJson()

proc extractFunctionCalls*(raw: JsonNode): seq[FunctionCall] =
  try:
    if raw.kind != JObject or (not raw.hasKey("candidates")):
      return @[]
    let candidates = raw["candidates"]
    if candidates.kind != JArray or candidates.len == 0:
      return @[]
    let content = candidates[0]["content"]
    if content.kind != JObject or (not content.hasKey("parts")):
      return @[]
    let parts = content["parts"]
    if parts.kind != JArray:
      return @[]
    for part in parts:
      if part.kind == JObject and part.hasKey("functionCall"):
        let fn = part["functionCall"]
        if fn.kind == JObject and fn.hasKey("name"):
          var args: JsonNode = newJObject()
          if fn.hasKey("args"):
            args = fn["args"]
          result.add(FunctionCall(name: fn["name"].getStr(), args: args))
  except CatchableError:
    result = @[]

proc extractText*(raw: JsonNode): string =
  ## Extracts concatenated text from the first candidate's parts.
  try:
    if raw.kind != JObject or (not raw.hasKey("candidates")):
      return ""
    let candidates = raw["candidates"]
    if candidates.kind != JArray or candidates.len == 0:
      return ""
    let content = candidates[0]["content"]
    if content.kind != JObject or (not content.hasKey("parts")):
      return ""
    let parts = content["parts"]
    if parts.kind != JArray:
      return ""
    var texts: seq[string] = @[]
    for part in parts:
      if part.kind == JObject and part.hasKey("text"):
        texts.add(part["text"].getStr())
    result = texts.join("")
  except CatchableError:
    result = ""

proc extractEmbeddings*(raw: JsonNode): seq[ContentEmbedding] =
  try:
    if raw.kind != JObject:
      return @[]
    if raw.hasKey("embeddings") and raw["embeddings"].kind == JArray:
      for item in raw["embeddings"]:
        if item.kind != JObject:
          continue
        var embedding = ContentEmbedding(values: @[], statistics: none(ContentEmbeddingStatistics))
        if item.hasKey("values") and item["values"].kind == JArray:
          for value in item["values"]:
            if value.kind in {JInt, JFloat}:
              embedding.values.add(value.getFloat())
        if item.hasKey("statistics") and item["statistics"].kind == JObject:
          var statistics = ContentEmbeddingStatistics()
          var hasStatistics = false
          let statsNode = item["statistics"]
          if statsNode.hasKey("truncated") and statsNode["truncated"].kind == JBool:
            statistics.truncated = some(statsNode["truncated"].getBool())
            hasStatistics = true
          if statsNode.hasKey("tokenCount") and statsNode["tokenCount"].kind in {JInt, JFloat}:
            statistics.tokenCount = some(statsNode["tokenCount"].getFloat())
            hasStatistics = true
          if hasStatistics:
            embedding.statistics = some(statistics)
        result.add(embedding)
  except CatchableError:
    result = @[]

proc extractEmbedContentMetadata*(raw: JsonNode): Option[EmbedContentMetadata] =
  try:
    if raw.kind != JObject or (not raw.hasKey("metadata")):
      return none(EmbedContentMetadata)
    let metadataNode = raw["metadata"]
    if metadataNode.kind != JObject:
      return none(EmbedContentMetadata)

    var metadata = EmbedContentMetadata()
    var hasMetadata = false
    if metadataNode.hasKey("billableCharacterCount"):
      let billableNode = metadataNode["billableCharacterCount"]
      if billableNode.kind == JInt:
        metadata.billableCharacterCount = some(billableNode.getInt())
        hasMetadata = true
      elif billableNode.kind == JFloat:
        metadata.billableCharacterCount = some(int(billableNode.getFloat()))
        hasMetadata = true
    if hasMetadata:
      return some(metadata)
  except CatchableError:
    discard
  result = none(EmbedContentMetadata)

proc extractSafetyAttributes*(raw: JsonNode): Option[SafetyAttributes] =
  try:
    if raw.kind != JObject:
      return none(SafetyAttributes)
    var safety = SafetyAttributes(
      categories: @[],
      scores: @[],
      contentType: none(string)
    )
    var hasAny = false

    if raw.hasKey("safetyAttributes") and raw["safetyAttributes"].kind == JObject:
      let attributes = raw["safetyAttributes"]
      if attributes.hasKey("categories") and attributes["categories"].kind == JArray:
        for category in attributes["categories"]:
          if category.kind == JString:
            safety.categories.add(category.getStr())
        hasAny = hasAny or safety.categories.len > 0
      if attributes.hasKey("scores") and attributes["scores"].kind == JArray:
        for score in attributes["scores"]:
          if score.kind in {JInt, JFloat}:
            safety.scores.add(score.getFloat())
        hasAny = hasAny or safety.scores.len > 0

    if raw.hasKey("contentType") and raw["contentType"].kind == JString:
      safety.contentType = some(raw["contentType"].getStr())
      hasAny = true

    if hasAny:
      return some(safety)
  except CatchableError:
    discard
  result = none(SafetyAttributes)

proc extractGeneratedImages*(raw: JsonNode): seq[GeneratedImage] =
  try:
    if raw.kind != JObject or (not raw.hasKey("predictions")):
      return @[]
    let predictions = raw["predictions"]
    if predictions.kind != JArray:
      return @[]

    for prediction in predictions:
      if prediction.kind != JObject:
        continue

      var generated = GeneratedImage(
        image: none(Image),
        raiFilteredReason: none(string),
        safetyAttributes: none(SafetyAttributes)
      )
      var hasAny = false

      if prediction.hasKey("bytesBase64Encoded") and prediction["bytesBase64Encoded"].kind == JString:
        let mimeType =
          if prediction.hasKey("mimeType") and prediction["mimeType"].kind == JString:
            prediction["mimeType"].getStr()
          else:
            ""
        generated.image = some(Image(
          mimeType: mimeType,
          bytesBase64: prediction["bytesBase64Encoded"].getStr()
        ))
        hasAny = true

      if prediction.hasKey("raiFilteredReason") and prediction["raiFilteredReason"].kind == JString:
        generated.raiFilteredReason = some(prediction["raiFilteredReason"].getStr())
        hasAny = true

      let safetyAttributes = extractSafetyAttributes(prediction)
      if safetyAttributes.isSome:
        generated.safetyAttributes = safetyAttributes
        hasAny = true

      if hasAny:
        result.add(generated)
  except CatchableError:
    result = @[]

proc extractVideo*(raw: JsonNode): Option[Video] =
  try:
    if raw.kind != JObject:
      return none(Video)

    var video = Video(
      uri: none(string),
      bytesBase64: none(string),
      mimeType: none(string)
    )
    var hasAny = false

    if raw.hasKey("uri") and raw["uri"].kind == JString:
      video.uri = some(raw["uri"].getStr())
      hasAny = true
    elif raw.hasKey("gcsUri") and raw["gcsUri"].kind == JString:
      video.uri = some(raw["gcsUri"].getStr())
      hasAny = true

    if raw.hasKey("encodedVideo") and raw["encodedVideo"].kind == JString:
      video.bytesBase64 = some(raw["encodedVideo"].getStr())
      hasAny = true
    elif raw.hasKey("bytesBase64Encoded") and raw["bytesBase64Encoded"].kind == JString:
      video.bytesBase64 = some(raw["bytesBase64Encoded"].getStr())
      hasAny = true

    if raw.hasKey("encoding") and raw["encoding"].kind == JString:
      video.mimeType = some(raw["encoding"].getStr())
      hasAny = true
    elif raw.hasKey("mimeType") and raw["mimeType"].kind == JString:
      video.mimeType = some(raw["mimeType"].getStr())
      hasAny = true

    if hasAny:
      return some(video)
  except CatchableError:
    discard
  result = none(Video)

proc extractGeneratedVideos*(raw: JsonNode): seq[GeneratedVideo] =
  try:
    if raw.kind != JObject:
      return @[]

    var samples: JsonNode = nil
    if raw.hasKey("generatedSamples") and raw["generatedSamples"].kind == JArray:
      samples = raw["generatedSamples"]
    elif raw.hasKey("videos") and raw["videos"].kind == JArray:
      samples = raw["videos"]
    elif raw.hasKey("generatedVideos") and raw["generatedVideos"].kind == JArray:
      samples = raw["generatedVideos"]
    elif raw.hasKey("generated_videos") and raw["generated_videos"].kind == JArray:
      samples = raw["generated_videos"]
    if samples.isNil:
      return @[]

    for sample in samples:
      if sample.kind != JObject:
        continue

      var videoNode: JsonNode = nil
      if sample.hasKey("video") and sample["video"].kind == JObject:
        videoNode = sample["video"]
      elif sample.hasKey("_self") and sample["_self"].kind == JObject:
        videoNode = sample["_self"]
      else:
        videoNode = sample

      let video = extractVideo(videoNode)
      if video.isSome:
        result.add(GeneratedVideo(video: video))
  except CatchableError:
    result = @[]

proc extractGenerateVideosResponse*(raw: JsonNode): Option[GenerateVideosResponse] =
  try:
    if raw.kind != JObject:
      return none(GenerateVideosResponse)

    var response = GenerateVideosResponse(
      generatedVideos: @[],
      raiMediaFilteredCount: none(int),
      raiMediaFilteredReasons: @[]
    )
    var hasAny = false

    response.generatedVideos = extractGeneratedVideos(raw)
    if response.generatedVideos.len > 0:
      hasAny = true

    if raw.hasKey("raiMediaFilteredCount"):
      let countNode = raw["raiMediaFilteredCount"]
      if countNode.kind == JInt:
        response.raiMediaFilteredCount = some(countNode.getInt())
        hasAny = true
      elif countNode.kind == JFloat:
        response.raiMediaFilteredCount = some(int(countNode.getFloat()))
        hasAny = true
    elif raw.hasKey("rai_media_filtered_count"):
      let countNode = raw["rai_media_filtered_count"]
      if countNode.kind == JInt:
        response.raiMediaFilteredCount = some(countNode.getInt())
        hasAny = true
      elif countNode.kind == JFloat:
        response.raiMediaFilteredCount = some(int(countNode.getFloat()))
        hasAny = true

    if raw.hasKey("raiMediaFilteredReasons") and raw["raiMediaFilteredReasons"].kind == JArray:
      for reason in raw["raiMediaFilteredReasons"]:
        if reason.kind == JString:
          response.raiMediaFilteredReasons.add(reason.getStr())
      hasAny = true
    elif raw.hasKey("rai_media_filtered_reasons") and raw["rai_media_filtered_reasons"].kind == JArray:
      for reason in raw["rai_media_filtered_reasons"]:
        if reason.kind == JString:
          response.raiMediaFilteredReasons.add(reason.getStr())
      hasAny = true

    if hasAny:
      return some(response)
  except CatchableError:
    discard
  result = none(GenerateVideosResponse)

proc parseGenerateVideosOperation*(raw: JsonNode): GenerateVideosOperation =
  result = GenerateVideosOperation(
    raw: raw,
    name: "",
    done: none(bool),
    metadata: newJNull(),
    error: newJNull(),
    response: none(GenerateVideosResponse),
    result: none(GenerateVideosResponse)
  )
  try:
    if raw.kind != JObject:
      return result

    if raw.hasKey("name") and raw["name"].kind == JString:
      result.name = raw["name"].getStr()

    if raw.hasKey("done") and raw["done"].kind == JBool:
      result.done = some(raw["done"].getBool())

    if raw.hasKey("metadata"):
      result.metadata = raw["metadata"]

    if raw.hasKey("error"):
      result.error = raw["error"]

    var responseNode: JsonNode = nil
    if raw.hasKey("response"):
      let response = raw["response"]
      if response.kind == JObject and response.hasKey("generateVideoResponse"):
        responseNode = response["generateVideoResponse"]
      elif response.kind == JObject:
        responseNode = response
    if responseNode.isNil and raw.hasKey("result"):
      let operationResult = raw["result"]
      if operationResult.kind == JObject and operationResult.hasKey("generateVideoResponse"):
        responseNode = operationResult["generateVideoResponse"]
      elif operationResult.kind == JObject:
        responseNode = operationResult

    if not responseNode.isNil:
      let parsedResponse = extractGenerateVideosResponse(responseNode)
      if parsedResponse.isSome:
        result.response = parsedResponse
        result.result = parsedResponse
  except CatchableError:
    discard
