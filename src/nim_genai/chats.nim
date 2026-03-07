import std/[asyncdispatch, options]

import ./client
import ./types

type
  ChatSession* = ref object
    client*: Client
    model*: string
    config*: GenerateContentConfig
    systemInstruction*: Option[Content]
    history*: seq[Content]

proc optionalSystemInstruction(systemInstruction: string): Option[Content] =
  if systemInstruction.len == 0:
    result = none(Content)
  else:
    result = some(systemInstructionFromText(systemInstruction))

proc newChatSession*(client: Client, model: string,
                     config: GenerateContentConfig = GenerateContentConfig(),
                     systemInstruction: string = ""): ChatSession =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")
  result = ChatSession(
    client: client,
    model: model,
    config: config,
    systemInstruction: optionalSystemInstruction(systemInstruction),
    history: @[]
  )

proc newChatSession*(client: Client, model: string,
                     config: GenerateContentConfig,
                     systemInstruction: Content): ChatSession =
  if client.isNil:
    raise newException(ValueError, "Client is nil")
  if model.len == 0:
    raise newException(ValueError, "model is required")
  result = ChatSession(
    client: client,
    model: model,
    config: config,
    systemInstruction: some(systemInstruction),
    history: @[]
  )

proc getHistory*(session: ChatSession): seq[Content] =
  if session.isNil:
    return @[]
  result = session.history

proc clearHistory*(session: ChatSession) =
  if session.isNil:
    return
  session.history.setLen(0)

proc setHistory*(session: ChatSession, history: seq[Content]) =
  if session.isNil:
    return
  session.history = history

proc modelContentFromResponse(response: GenerateContentResponse): Option[Content] =
  if response.text.len > 0:
    return some(contentFromText(response.text, role = "model"))
  if response.functionCalls.len > 0:
    var parts: seq[Part] = @[]
    for functionCall in response.functionCalls:
      parts.add(partFromFunctionCall(functionCall.name, functionCall.args))
    return some(contentFromParts(parts, role = "model"))
  result = none(Content)

proc sendMessage*(session: ChatSession, content: Content): Future[GenerateContentResponse]
                  {.async.} =
  if session.isNil:
    raise newException(ValueError, "ChatSession is nil")
  if content.parts.len == 0:
    raise newException(ValueError, "content.parts is required")

  var requestContents = session.history
  requestContents.add(content)

  var response: GenerateContentResponse
  if session.systemInstruction.isSome:
    response = await session.client.generateContent(
      model = session.model,
      contents = requestContents,
      config = session.config,
      systemInstruction = session.systemInstruction.get()
    )
  else:
    response = await session.client.generateContent(
      model = session.model,
      contents = requestContents,
      config = session.config
    )

  session.history.add(content)
  let modelContent = modelContentFromResponse(response)
  if modelContent.isSome:
    session.history.add(modelContent.get())

  result = response

proc sendMessage*(session: ChatSession, message: string): Future[GenerateContentResponse]
                  {.async.} =
  if message.len == 0:
    raise newException(ValueError, "message is required")
  result = await session.sendMessage(contentFromText(message))
