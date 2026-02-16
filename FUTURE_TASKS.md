# Future Tasks (from python-genai)

This file lists features and modules present in `python-genai` that are not
implemented in the current Nim MVP.

## API Coverage
- [x] Streaming (`generateContentStream`) for text (SSE)
- [x] Multimodal parts for `generateContent` (images, files, inline data)
- [ ] Tool calls / function calling in `generateContent`
- [ ] System instruction as structured content
- [ ] Embeddings / `embedContent`
- [ ] Image generation / editing / upscaling
- [ ] Video generation / extension (Veo)
- [ ] Audio / speech features
- [ ] Files API (upload, list, delete)
- [ ] File search stores
- [ ] Caches API
- [ ] Batches API
- [ ] Operations / long‑running operations (LRO)
- [ ] Tunings / fine‑tuning
- [ ] Tokens API (count tokens)
- [ ] Models API (list/get model metadata)
- [ ] Chats / sessions
- [ ] Documents API
- [ ] Interactions API
- [ ] Live API / Live music

## Client & Auth
- [ ] Sync client API (non‑async)
- [ ] Context manager / auto‑close
- [ ] Vertex AI support (project, location, endpoints)
- [ ] ADC / service account auth
- [ ] Custom base URL / API version overrides per request
- [ ] Base URL overrides via environment variables
- [ ] HTTP options (timeouts, proxy, retries, custom headers)
- [ ] Built‑in pagination helpers

## Tooling & UX
- [ ] Function calling / automatic function calling
- [ ] Structured output / response schema helpers
- [ ] Safety settings & moderation config helpers
- [ ] Full request/response type coverage (parity with `types.py`)
- [ ] Dict‑style request inputs
- [ ] Request/response converters and adapters
- [ ] Local tokenizer utilities
- [ ] MCP utilities

## Quality
- [ ] Tests (unit + integration)
- [ ] Examples directory
- [ ] CI workflow
