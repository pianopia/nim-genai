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

  GenerateContentResponse* = object
    raw*: JsonNode
    text*: string
    functionCalls*: seq[FunctionCall]

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
