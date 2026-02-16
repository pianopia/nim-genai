import std/strutils

type
  SseLineParser* = object
    lineBuffer*: string
    errorBuffer*: string
    errorBraceBalance*: int

proc processSseLine(parser: var SseLineParser, rawLine: string,
                    payloads: var seq[string]) =
  var line = rawLine
  if line.len > 0 and line[^1] == '\r':
    line.setLen(line.len - 1)

  if line.len == 0:
    return

  if line.startsWith("data:"):
    var payload = line[5 .. ^1]
    if payload.len > 0 and payload[0] == ' ':
      payload = payload[1 .. ^1]
    payloads.add(payload)
    return

  # Fallback for error responses that are not prefixed by `data:`.
  for c in line:
    if c == '{':
      inc(parser.errorBraceBalance)
    elif c == '}':
      dec(parser.errorBraceBalance)
  parser.errorBuffer.add(line)
  if parser.errorBuffer.len > 0 and parser.errorBraceBalance == 0:
    payloads.add(parser.errorBuffer)
    parser.errorBuffer.setLen(0)

proc consumeSseChunk*(parser: var SseLineParser, chunk: string): seq[string] =
  parser.lineBuffer.add(chunk)

  var start = 0
  while true:
    let lineEnd = parser.lineBuffer.find('\n', start)
    if lineEnd < 0:
      break

    let line = parser.lineBuffer[start ..< lineEnd]
    parser.processSseLine(line, result)
    start = lineEnd + 1

  if start > 0:
    if start >= parser.lineBuffer.len:
      parser.lineBuffer.setLen(0)
    else:
      parser.lineBuffer = parser.lineBuffer[start .. ^1]

proc flushSseChunkParser*(parser: var SseLineParser): seq[string] =
  if parser.lineBuffer.len > 0:
    parser.lineBuffer.add('\n')
    result.add(parser.consumeSseChunk(""))

  if parser.errorBuffer.len > 0:
    result.add(parser.errorBuffer)
    parser.errorBuffer.setLen(0)
    parser.errorBraceBalance = 0
