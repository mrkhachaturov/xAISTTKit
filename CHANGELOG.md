# Changelog

## 0.2.0 — WebSocket streaming STT

- Add `xAISTTWebSocketSession` actor — real-time transcription over `wss://api.x.ai/v1/stt`
- Sends raw audio as binary frames in the negotiated `encoding` (pcm / mulaw / alaw), signals end with `{"type":"audio.done"}` per spec
- Public `Event` enum: `.ready` (transcript.created), `.partial(Transcript)` (interim / chunk-final / utterance-final), `.done(Transcript)`, `.error(message:)` — `Sendable` and `Equatable`
- `Transcript` carries `text`, `isFinal`, `speechFinal`, `start`, `duration`, `channelIndex`, optional word-level segments — covers interim, chunk-final, utterance-final, and multichannel cases
- Query-parameter coverage: `sample_rate`, `encoding`, `language`, `interim_results`, `endpointing`, `diarize`, `filler_words`, `multichannel`, `channels`, repeated `keyterm`
- Single-utterance convenience: `xAISTTWebSocketSession.transcribe(pcm16Chunks:configuration:) -> String` for "stream this PCM buffer, give me the transcript" use cases
- Auth via `Sec-WebSocket-Protocol: xai-client-secret.<bearer>` to work around `URLSessionWebSocketTask`'s Authorization-header stripping on Apple platforms
- 14 new Swift Testing tests covering URL defaults & full coverage, auth subprotocol formatting, audio.done frame shape, and event decoding (ready, all three partial states, done with words+channel_index, error, malformed)
- `xAISTTResponse.Word` and `Channel` now conform to `Equatable` so streaming `Transcript` events can be diffed

## 0.1.0 — initial release

- REST transcription client (`xAISTTClient.transcribe`) for xAI Grok `POST /v1/stt`
- Multipart body construction with field-order enforcement (`file` is always last per the xAI spec)
- Three transcription paths: in-memory `Data`, remote `URL`, and PCM16 → WAV convenience wrapper
- Type-safe `xAISTTLanguage` enum (25 ISO codes) and `xAISTTAudioFormat` (pcm / mulaw / alaw)
- Structured `xAISTTResponse` with optional words, channels, language, duration, and speaker diarization
- Structured `xAISTTError` type
- Actor-based concurrency, `Sendable` everywhere, zero external dependencies
- Swift Testing suite (14 tests) covering language coverage, body shape, file-last invariant, repeated keyterm handling, WAV header bytes, and response decoding
