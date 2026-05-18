# Changelog

## 0.3.1 — nonisolated audio helper

- Drop `@MainActor` from `xAISTTAudioInputTap.install` / `stop` / `finish`. Callable from any isolation domain, matching `AVAudioEngine`'s own contract — no forced main-thread hop when bootstrapping audio off-main.

## 0.3.0 — AVAudioEngine mic-tap helper

- Add `xAISTTAudioInputTap` — installs a tap on an externally-managed `AVAudioEngine.inputNode`, converts to 16 kHz mono PCM16 via `AVAudioConverter`, and exposes three streams:
  - `pcm16Chunks: AsyncStream<Data>` — every converted buffer (pipe into `xAISTTWebSocketSession.send(audio:)`)
  - `utterances: AsyncStream<Utterance>` — silence-segmented utterances ready for `xAISTTClient.transcribe(audio:)` (PCM + WAV-wrapped buffer + duration)
  - `rmsLevels: AsyncStream<Float>` — rolling RMS for UI level metering
- Internal silence-based segmenter with sensible defaults (`silenceThresholdMs: 700`, `minimumUtteranceMs: 400`, `voiceRMSThreshold: 0.005`); state isolated by `OSAllocatedUnfairLock` so it's safe to call from the audio render thread
- Adds 6 tests covering the segmenter state machine (no audio engine required) and the public defaults

## 0.2.0 — WebSocket streaming STT

- Add `xAISTTWebSocketSession` actor — real-time transcription over `wss://api.x.ai/v1/stt`
- Sends raw audio as binary frames in the negotiated `encoding` (pcm / mulaw / alaw), signals end with `{"type":"audio.done"}` per spec
- Public `Event` enum: `.ready` (transcript.created), `.partial(Transcript)` (interim / chunk-final / utterance-final), `.done(Transcript)`, `.error(message:)` — `Sendable` and `Equatable`
- `Transcript` carries `text`, `isFinal`, `speechFinal`, `start`, `duration`, `channelIndex`, optional word-level segments
- Query-parameter coverage: `sample_rate`, `encoding`, `language`, `interim_results`, `endpointing`, `diarize`, `filler_words`, `multichannel`, `channels`, repeated `keyterm`
- Single-utterance convenience: `xAISTTWebSocketSession.transcribe(pcm16Chunks:configuration:) -> String`
- Auth via `Sec-WebSocket-Protocol: xai-client-secret.<bearer>` to work around `URLSessionWebSocketTask`'s Authorization-header stripping on Apple platforms
- `xAISTTResponse.Word` and `Channel` now conform to `Equatable`

## 0.1.0 — initial release

- REST transcription client (`xAISTTClient.transcribe`) for xAI Grok `POST /v1/stt`
- Multipart body construction with field-order enforcement (`file` is always last per the xAI spec)
- Three transcription paths: in-memory `Data`, remote `URL`, and PCM16 → WAV convenience wrapper
- Type-safe `xAISTTLanguage` enum (25 ISO codes) and `xAISTTAudioFormat` (pcm / mulaw / alaw)
- Structured `xAISTTResponse` with optional words, channels, language, duration, and speaker diarization
- Structured `xAISTTError` type
- Actor-based concurrency, `Sendable` everywhere, zero external dependencies
