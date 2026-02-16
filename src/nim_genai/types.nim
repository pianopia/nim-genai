import std/[json, options, strutils]

type
  Part* = object
    text*: string

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
  Part(text: text)

proc contentFromText*(text: string; role = "user"): Content =
  Content(role: role, parts: @[partFromText(text)])

proc toJson*(part: Part): JsonNode =
  result = newJObject()
  result["text"] = %part.text

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
