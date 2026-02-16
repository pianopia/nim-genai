# nim-genai (MVP)

Nim client for Google GenAI (Gemini API). This is a minimal, async-only
implementation focused on text generation.

## Requirements

- Nim 2.2+
- Compile with SSL enabled for HTTPS:

```sh
nim c -d:ssl your_app.nim
```

## Usage

```nim
import std/[asyncdispatch, options]
import nim_genai

proc main() {.async.} =
  let client = newClient(apiKey = "YOUR_API_KEY")

  let resp = await client.generateContent(
    model = "gemini-2.5-flash",
    prompt = "Why is the sky blue?",
    config = GenerateContentConfig(
      temperature: some(0.0),
      topP: some(0.95),
      topK: some(20)
    )
  )

  echo resp.text
  client.close()

waitFor main()
```

## Streaming Usage

```nim
import std/asyncdispatch
import nim_genai

proc main() {.async.} =
  let client = newClient(apiKey = "YOUR_API_KEY")
  let stream = client.generateContentStream(
    model = "gemini-2.5-flash",
    prompt = "Write a haiku about Nim."
  )

  while true:
    let (hasChunk, chunk) = await stream.read()
    if not hasChunk:
      break
    stdout.write(chunk.text)
  echo ""

  client.close()

waitFor main()
```

You can also import using the module name with backticks:

```nim
import `nim-genai`
```

Note: the Nimble package name is `nim_genai` (hyphens are not allowed).

### API Key

If `apiKey` is not provided, the client will read `GOOGLE_API_KEY` and then
`GEMINI_API_KEY` from the environment.

## Notes

- This MVP supports `generateContent` and `generateContentStream` for text.
- Vertex AI and most advanced APIs are not implemented yet (see
  `/Users/nakagawa_shota/repo/valit/nim-genai/FUTURE_TASKS.md`).
