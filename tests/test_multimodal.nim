import std/[json, options, unittest]

import ../src/nim_genai/types

suite "Multimodal parts":
  test "text part serializes to text payload":
    let p = partFromText("hello")
    let j = p.toJson()
    check j["text"].getStr() == "hello"

  test "inline base64 part serializes to inlineData payload":
    let p = partFromInlineData("image/png", "AQID")
    let j = p.toJson()
    check j["inlineData"]["mimeType"].getStr() == "image/png"
    check j["inlineData"]["data"].getStr() == "AQID"

  test "bytes helper encodes payload as base64":
    let p = partFromBytes([1'u8, 2'u8, 3'u8], "application/octet-stream")
    let j = p.toJson()
    check j["inlineData"]["mimeType"].getStr() == "application/octet-stream"
    check j["inlineData"]["data"].getStr() == "AQID"

  test "file uri part serializes to fileData payload":
    let p = partFromFileUri("gs://bucket/image.png", "image/png")
    let j = p.toJson()
    check j["fileData"]["mimeType"].getStr() == "image/png"
    check j["fileData"]["fileUri"].getStr() == "gs://bucket/image.png"

  test "content supports mixed multimodal parts":
    let content = contentFromParts(@[
      partFromText("What is in this image?"),
      partFromFileUri("gs://bucket/image.png", "image/png"),
      partFromInlineData("application/pdf", "AQID")
    ])
    let j = content.toJson()
    check j["role"].getStr() == "user"
    check j["parts"].kind == JArray
    check j["parts"].len == 3
    check j["parts"][0]["text"].getStr() == "What is in this image?"
    check j["parts"][1]["fileData"]["fileUri"].getStr() == "gs://bucket/image.png"
    check j["parts"][2]["inlineData"]["mimeType"].getStr() == "application/pdf"

  test "system instruction content uses system role":
    let si = systemInstructionFromText("Only answer in JSON.")
    let j = si.toJson()
    check j["role"].getStr() == "system"
    check j["parts"][0]["text"].getStr() == "Only answer in JSON."

  test "function call and function response parts serialize":
    let functionCallPart = partFromFunctionCall("getWeather", %*{"city": "Tokyo"})
    let functionResponsePart = partFromFunctionResponse(
      "getWeather",
      %*{"temperature": 21, "unit": "celsius"}
    )
    let callJson = functionCallPart.toJson()
    let responseJson = functionResponsePart.toJson()
    check callJson["functionCall"]["name"].getStr() == "getWeather"
    check callJson["functionCall"]["args"]["city"].getStr() == "Tokyo"
    check responseJson["functionResponse"]["name"].getStr() == "getWeather"
    check responseJson["functionResponse"]["response"]["temperature"].getInt() == 21

  test "tool declarations and tool config serialize":
    let decl = functionDeclaration(
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
    let cfg = GenerateContentConfig(
      tools: @[toolFromFunctions(@[decl])],
      toolConfig: some(toolConfig(functionCallingConfig(
        mode = fcmAny,
        allowedFunctionNames = @["getWeather"]
      )))
    )
    let j = cfg.toJson()
    check j["tools"].kind == JArray
    check j["tools"].len == 1
    check j["tools"][0]["functionDeclarations"][0]["name"].getStr() == "getWeather"
    check j["toolConfig"]["functionCallingConfig"]["mode"].getStr() == "ANY"
    check j["toolConfig"]["functionCallingConfig"]["allowedFunctionNames"][0].getStr() == "getWeather"

  test "automatic function calling config serializes":
    let cfg = GenerateContentConfig(
      automaticFunctionCalling: some(automaticFunctionCallingConfig(
        disable = some(false),
        maximumRemoteCalls = some(5),
        ignoreCallHistory = some(false)
      ))
    )
    let j = cfg.toJson()
    check j["automaticFunctionCalling"]["disable"].getBool() == false
    check j["automaticFunctionCalling"]["maximumRemoteCalls"].getInt() == 5
    check j["automaticFunctionCalling"]["ignoreCallHistory"].getBool() == false

  test "extracts function calls from response payload":
    let raw = %*{
      "candidates": [
        {
          "content": {
            "parts": [
              {
                "functionCall": {
                  "name": "getWeather",
                  "args": {
                    "city": "Tokyo"
                  }
                }
              }
            ]
          }
        }
      ]
    }
    let calls = extractFunctionCalls(raw)
    check calls.len == 1
    check calls[0].name == "getWeather"
    check calls[0].args["city"].getStr() == "Tokyo"
