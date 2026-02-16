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

You can also import using the module name with backticks:

```nim
import `nim-genai`
```

Note: the Nimble package name is `nim_genai` (hyphens are not allowed).

### API Key

If `apiKey` is not provided, the client will read `GOOGLE_API_KEY` and then
`GEMINI_API_KEY` from the environment.

## Notes

- This MVP only supports `generateContent` with text prompts.
- Streaming, Vertex AI, and other features are not implemented yet (see
  `FUTURE_TASKS.md`).
