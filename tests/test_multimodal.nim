import std/[json, unittest]

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
