import std/[base64, json, options, strutils]

type
  PartKind* = enum
    pkText,
    pkInlineData,
    pkFileData

  InlineData* = object
    mimeType*: string
    data*: string

  FileData* = object
    mimeType*: string
    fileUri*: string

  Part* = object
    case kind*: PartKind
    of pkText:
      text*: string
    of pkInlineData:
      inlineData*: InlineData
    of pkFileData:
      fileData*: FileData

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

  GenerateContentResponse* = object
    raw*: JsonNode
    text*: string

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

proc contentFromText*(text: string; role = "user"): Content =
  Content(role: role, parts: @[partFromText(text)])

proc contentFromParts*(parts: seq[Part]; role = "user"): Content =
  Content(role: role, parts: parts)

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
