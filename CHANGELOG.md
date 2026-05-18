# Changelog

## 0.1.0 — initial release

- REST transcription client (`xAISTTClient.transcribe`) for xAI Grok `POST /v1/stt`
- Multipart body construction with field-order enforcement (`file` is always last per the xAI spec)
- Three transcription paths: in-memory `Data`, remote `URL`, and PCM16 → WAV convenience wrapper
- Type-safe `xAISTTLanguage` enum (25 ISO codes) and `xAISTTAudioFormat` (pcm / mulaw / alaw)
- Structured `xAISTTResponse` with optional words, channels, language, duration, and speaker diarization
- Structured `xAISTTError` type
- Actor-based concurrency, `Sendable` everywhere, zero external dependencies
- Swift Testing suite (15 tests) covering language coverage, body shape, file-last invariant, repeated keyterm handling, WAV header bytes, and response decoding

## Roadmap

- `v0.2.0` — WebSocket streaming STT (`wss://api.x.ai/v1/stt`), interim results, multichannel streaming
