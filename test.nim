import std/[asyncdispatch, options]
import nim_genai

proc main() {.async.} =
  let client = newClient(apiKey = "YOUR_API_KEY")
  let resp = await client.generateContent(
    model = "gemini-2.5-flash",
    prompt = "Hello from Nim!"
  )
  echo resp.text
  client.close()

waitFor main()
