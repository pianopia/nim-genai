# nim-genai (MVP)

Nim client for Google GenAI (Gemini API). This is a minimal, async-only
implementation focused on core generation APIs.

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

## Multimodal Usage

```nim
import std/asyncdispatch
import nim_genai

proc main() {.async.} =
  let client = newClient(apiKey = "YOUR_API_KEY")

  let content = contentFromParts(@[
    partFromText("Describe this image."),
    partFromFileUri("gs://my-bucket/cat.png", "image/png"),
    # Inline bytes must be base64-encoded.
    partFromInlineData("application/pdf", "BASE64_DATA_HERE")
  ])

  let resp = await client.generateContent(
    model = "gemini-2.5-flash",
    contents = @[content]
  )

  echo resp.text
  client.close()

waitFor main()
```

## Structured System Instruction

```nim
import std/asyncdispatch
import nim_genai

proc main() {.async.} =
  let client = newClient(apiKey = "YOUR_API_KEY")
  let systemInstruction = contentFromParts(@[
    partFromText("You are a strict JSON API."),
    partFromText("Always respond with a single JSON object.")
  ], role = "system")

  let resp = await client.generateContent(
    model = "gemini-2.5-flash",
    prompt = "Give me today's weather format.",
    config = GenerateContentConfig(),
    systemInstruction = systemInstruction
  )

  echo resp.text
  client.close()

waitFor main()
```

## Function Calling

```nim
import std/[asyncdispatch, json, options]
import nim_genai

proc main() {.async.} =
  let client = newClient(apiKey = "YOUR_API_KEY")

  let getWeatherDecl = functionDeclaration(
    "getWeather",
    "Returns weather by city.",
    %*{
      "type": "object",
      "properties": {
        "city": {"type": "string"}
      },
      "required": ["city"]
    }
  )

  let config = GenerateContentConfig(
    tools: @[toolFromFunctions(@[getWeatherDecl])],
    automaticFunctionCalling: some(automaticFunctionCallingConfig(
      disable = some(false),
      maximumRemoteCalls = some(5)
    )))
  )
  var handlers = newFunctionHandlerMap()
  handlers.setFunctionHandler(
    "getWeather",
    proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
      result = %*{
        "city": args["city"].getStr(),
        "temperature": 21,
        "unit": "celsius"
      }
  )

  let response = await client.generateContentAfc(
    model = "gemini-2.5-flash",
    prompt = "What's the weather in Tokyo?",
    functionHandlers = handlers,
    config = config
  )
  echo response.text

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

## Embeddings (`embedContent`)

```nim
import std/[asyncdispatch, options]
import nim_genai

proc main() {.async.} =
  let client = newClient(apiKey = "YOUR_API_KEY")

  let response = await client.embedContent(
    model = "text-embedding-004",
    texts = @["What is your name?", "I am a model."],
    config = embedContentConfig(
      taskType = some("RETRIEVAL_DOCUMENT"),
      title = some("example-doc"),
      outputDimensionality = some(128)
    )
  )

  echo "embedding count: ", response.embeddings.len
  if response.embeddings.len > 0:
    echo "first vector length: ", response.embeddings[0].values.len

  client.close()

waitFor main()
```

## Image generation / editing / upscaling

```nim
import std/[asyncdispatch, base64, options]
import nim_genai

proc main() {.async.} =
  let client = newClient(apiKey = "YOUR_API_KEY")

  let generated = await client.generateImages(
    model = "imagen-4.0-generate-001",
    prompt = "A red skateboard on white background",
    config = generateImagesConfig(
      numberOfImages = some(1),
      outputMimeType = some("image/png")
    )
  )
  if generated.generatedImages.len > 0 and generated.generatedImages[0].image.isSome:
    let pngBytes = decode(generated.generatedImages[0].image.get().bytesBase64)
    writeFile("generated.png", pngBytes)

  let edited = await client.editImage(
    model = "imagen-4.0-generate-001",
    prompt = "Replace background with a beach",
    image = imageFromBytes(readFile("generated.png"), "image/png"),
    config = editImageConfig(editMode = some("EDIT_MODE_INPAINT_INSERTION"))
  )
  discard edited

  let upscaled = await client.upscaleImage(
    model = "imagen-4.0-upscale-preview",
    image = imageFromBytes(readFile("generated.png"), "image/png"),
    upscaleFactor = "x2",
    config = upscaleImageConfig(enhanceInputImage = some(true))
  )
  discard upscaled

  client.close()

waitFor main()
```

## Video generation / extension (Veo)

```nim
import std/[asyncdispatch, options]
import nim_genai

proc main() {.async.} =
  let client = newClient(apiKey = "YOUR_API_KEY")

  var operation = await client.generateVideos(
    model = "veo-2.0-generate-001",
    source = generateVideosSource(
      prompt = some("A neon hologram of a cat driving at top speed")
    ),
    config = generateVideosConfig(
      numberOfVideos = some(1),
      durationSeconds = some(6)
    )
  )

  while (not operation.done.isSome) or (not operation.done.get()):
    # Poll long-running operation status.
    operation = await client.getOperation(operation)

  if operation.result.isSome and operation.result.get().generatedVideos.len > 0:
    let generated = operation.result.get().generatedVideos[0]
    if generated.video.isSome and generated.video.get().uri.isSome:
      echo generated.video.get().uri.get()

  # Video extension: pass an input video in source.video.
  discard await client.generateVideos(
    model = "veo-2.0-generate-001",
    source = generateVideosSource(
      prompt = some("Continue this video with sunrise"),
      video = some(videoFromUri("gs://my-bucket/base.mp4", some("video/mp4")))
    )
  )

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

- This MVP supports `generateContent`, `generateContentStream`, `embedContent`,
  and Veo `generateVideos` (+ `getOperation` polling).
- Image APIs (`generateImages`, `editImage`, `upscaleImage`) are available via Imagen `:predict`.
- `generateContent` supports text, `inlineData`, and `fileData` parts.
- `systemInstruction` supports both text and structured `Content`.
- Basic tool declarations, function calls, and automatic function calling are supported.
- Vertex AI and most advanced APIs are not implemented yet (see
  `/Users/nakagawa_shota/repo/valit/nim-genai/FUTURE_TASKS.md`).
