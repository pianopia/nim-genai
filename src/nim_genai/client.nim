import std/[asyncdispatch, httpclient, json, options, os, strutils]

import ./types
import ./errors

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

proc buildGenerateContentRequest(contents: seq[Content],
                                 config: GenerateContentConfig,
                                 systemInstruction: string): JsonNode =
  result = newJObject()

  let contentsNode = newJArray()
  for content in contents:
    contentsNode.add(content.toJson())
  result["contents"] = contentsNode

  if systemInstruction.len > 0:
    let systemNode = newJObject()
    let partsNode = newJArray()
    partsNode.add(%*{"text": systemInstruction})
    systemNode["parts"] = partsNode
    result["systemInstruction"] = systemNode

  let configNode = config.toJson()
  if configNode.len > 0:
    result["generationConfig"] = configNode

proc generateContent*(client: Client, model: string, contents: seq[Content],
                      config: GenerateContentConfig = GenerateContentConfig(),
                      systemInstruction: string = ""): Future[GenerateContentResponse]
                      {.async.} =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")
  if contents.len == 0:
    raise newException(ValueError, "contents is required")

  let modelPath = normalizeModelPath(model)
  let path = client.apiVersion & "/" & modelPath & ":generateContent"
  let url = joinUrl(client.baseUrl, path)

  let bodyJson = buildGenerateContentRequest(contents, config, systemInstruction)
  let bodyStr = $bodyJson

  let resp = await client.http.request(url, HttpPost, body = bodyStr)
  let statusCode = resp.code.int
  let respBody = await resp.body()

  if statusCode < 200 or statusCode >= 300:
    raise newGenAIError(statusCode, respBody)

  let raw = parseJson(respBody)
  let text = extractText(raw)
  result = GenerateContentResponse(raw: raw, text: text)

proc generateContent*(client: Client, model: string, prompt: string,
                      config: GenerateContentConfig = GenerateContentConfig(),
                      systemInstruction: string = ""): Future[GenerateContentResponse]
                      {.async.} =
  let content = contentFromText(prompt)
  result = await client.generateContent(model, @[content], config, systemInstruction)
