type
  GenAIError* = object of CatchableError
    statusCode*: int
    responseBody*: string

proc newGenAIError*(statusCode: int, responseBody: string): ref GenAIError =
  let e = newException(GenAIError, "GenAI API error (HTTP " & $statusCode & ")")
  e.statusCode = statusCode
  e.responseBody = responseBody
  return e

proc formatGenAIError*(e: ref GenAIError): string =
  if e.responseBody.len > 0:
    result = e.msg & ": " & e.responseBody
  else:
    result = e.msg
