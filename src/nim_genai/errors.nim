type
  GenAIError* = object of CatchableError
    statusCode*: int
    responseBody*: string

proc newGenAIError*(statusCode: int, responseBody: string): ref GenAIError =
  var msg = "GenAI API error (HTTP " & $statusCode & ")"
  if responseBody.len > 0:
    var body = responseBody
    const maxLen = 4096
    if body.len > maxLen:
      body = body[0 ..< maxLen] & "…"
    msg.add(": " & body)
  let e = newException(GenAIError, msg)
  e.statusCode = statusCode
  e.responseBody = responseBody
  return e

proc formatGenAIError*(e: ref GenAIError): string =
  if e.responseBody.len > 0:
    result = e.msg & ": " & e.responseBody
  else:
    result = e.msg
