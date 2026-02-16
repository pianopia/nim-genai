cat > /tmp/quickstart.nim <<'NIM'
import std/[asyncdispatch, options]
import nim_genai

proc main() {.async.} =
  let client = newClient(apiKey = "YOUR_API_KEY")
  let resp = await client.generateContent(
    model = "gemini-2.5-flash",
    prompt = "Hello from Nim!",
    config = GenerateContentConfig(temperature: some(0.2))
  )
  echo resp.text
  client.close()

waitFor main()
NIM

nim c -d:ssl -r /tmp/quickstart.nim

