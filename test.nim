import std/[asyncdispatch, options]
import nim_genai

proc main() {.async.} =
  let client = newClient(apiKey = "")
  let resp = await client.generateContent(
    model = "gemini-3-pro-preview",
    prompt = "Hello from Nim!"
  )
  echo resp.text
  client.close()

waitFor main()
