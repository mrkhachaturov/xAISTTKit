# xAISTTKit — xAI Grok STT on tap, SwiftPM-friendly, async-native.

Swift client for [xAI Grok Speech-to-Text](https://docs.x.ai/docs/speech-to-text) on Apple platforms (iOS/macOS).

![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2018%2B%20%7C%20macOS%2015%2B-blue)
![License](https://img.shields.io/badge/License-MIT-green)

> Brand convention: the brand is **xAI** (lowercase `x`, uppercase `AI`).
> All public types follow suit — `xAISTTClient`, `xAISTTLanguage`,
> `xAISTTAudioFormat`, `xAISTTResponse`, `xAISTTError`. This is an intentional
> violation of the Swift API Design Guidelines in favor of brand fidelity.
> Don't "fix" it.

## What's Included

- REST transcription client (`POST /v1/stt`, multipart/form-data)
- Three transcription paths:
  - `transcribe(audio:filename:contentType:…)` — in-memory `Data` upload
  - `transcribe(url:…)` — remote audio fetched server-side
  - `transcribePCM16(_:sampleRate:…)` — convenience that wraps raw 16-bit PCM in a WAV header
- Field-order enforcement: `file` is always the last multipart field (per xAI spec)
- Type-safe `xAISTTLanguage` enum (25 ISO codes) and `xAISTTAudioFormat` (`pcm`/`mulaw`/`alaw`)
- Structured `xAISTTResponse` (text, language, duration, words, channels, speaker diarization)
- Structured `xAISTTError`
- Actor-based concurrency, `Sendable` everywhere, zero external dependencies

## Requirements

- Swift 6.2 (SwiftPM `swift-tools-version: 6.2`)
- iOS 18+
- macOS 15+

## Install (Swift Package Manager)

### Xcode

**File > Add Package Dependencies...** and enter:
```
https://github.com/mrkhachaturov/xAISTTKit.git
```

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/mrkhachaturov/xAISTTKit.git", from: "0.1.0"),
]
```

## Quick Start

```swift
import xAISTTKit

let client = xAISTTClient(config: .init(bearer: "<xai-api-key-or-oauth-bearer>"))

let audio = try Data(contentsOf: URL(fileURLWithPath: "meeting.mp3"))
let result = try await client.transcribe(
    audio: audio,
    filename: "meeting.mp3",
    contentType: "audio/mpeg",
    language: .en,
    options: .init(format: true, keyTerms: ["Understand The Universe"])
)

print(result.text)
print("Duration: \(result.duration ?? 0)s")
for word in result.words ?? [] {
    print("  \(word.start)s – \(word.end)s: \(word.text)")
}
```

## PCM16 from `AVAudioEngine`

When you have raw 16-bit little-endian PCM samples (e.g. from an `AVAudioEngine`
input tap converted to a target format), use `transcribePCM16` — it stitches a
minimal RIFF/WAVE header so the server auto-detects the container:

```swift
let result = try await client.transcribePCM16(
    pcmSamples,           // Data of Int16 LE samples
    sampleRate: 16_000,
    channels: 1,
    language: .en
)
```

## Server-side fetch (no upload)

```swift
let result = try await client.transcribe(
    url: URL(string: "https://example.com/clip.mp3")!,
    language: .en
)
```

## Languages

`xAISTTLanguage` covers all 25 codes the xAI spec lists:

```
.ar, .cs, .da, .nl, .en, .fil, .fr, .de, .hi, .id, .it, .ja, .ko,
.mk, .ms, .fa, .pl, .pt, .ro, .ru, .es, .sv, .th, .tr, .vi
```

The language parameter is **optional** — the model transcribes any of these
regardless. Passing it enables Inverse Text Normalization (numbers and
currencies in their written form, e.g. `"one hundred dollars" → "$100"`) when
combined with `options.format = true`.

## Options

`xAISTTClient.Options` mirrors the xAI multipart form fields. All optional —
only non-nil values are sent.

| Option | Spec field | Notes |
|--------|-----------|-------|
| `format` | `format` | Inverse Text Normalization. Requires `language`. |
| `audioFormat` | `audio_format` | Only for raw audio (`pcm`/`mulaw`/`alaw`). |
| `sampleRate` | `sample_rate` | Required when `audioFormat` is set. |
| `multichannel` | `multichannel` | Transcribe each channel independently. |
| `channels` | `channels` | 2–8. Only required for raw multichannel audio. |
| `diarize` | `diarize` | Adds `speaker` to each word. |
| `fillerWords` | `filler_words` | Include "uh", "um", etc. |
| `keyTerms` | `keyterm` (repeated) | Up to 100 terms, 50 chars each. |

## Audio Formats

| Format | Notes |
|--------|-------|
| WAV / MP3 / OGG / Opus / FLAC / AAC / MP4 / M4A / MKV | Container formats — auto-detected, just upload the bytes |
| `.pcm` (`Int16` LE) / `.mulaw` / `.alaw` | Headerless — must set `options.audioFormat` AND `options.sampleRate` |

Max file size: **500 MB** (enforced client-side).

## Auth

Pass either:

- The xAI OAuth bearer minted by the OpenClaw gateway (preferred — shipped to
  iOS clients via `talk.config`), or
- A static `XAI_API_KEY` obtained from the [xAI console](https://console.x.ai/team/default/api-keys).

Both go in the `Authorization: Bearer …` header — the client doesn't care which.

## Error Handling

```swift
do {
    let result = try await client.transcribe(audio: data, language: .en)
    print(result.text)
} catch let error as xAISTTError {
    switch error {
    case .http(let status, let body):
        print("xAI returned HTTP \(status): \(body ?? "<no body>")")
    case .fileTooLarge(let max, let got):
        print("Audio too large: \(got)/\(max) bytes")
    case .formatRequiresLanguage:
        print("Pass a language when using format=true")
    default:
        print("xAI STT error: \(error.errorDescription ?? "<unknown>")")
    }
}
```

## Limits

- Max file size: **500 MB**
- Sample rates: `8000`, `16000`, `22050`, `24000`, `44100`, `48000` Hz
- Channels: mono, stereo, or up to 8 (with `multichannel: true`)

## Roadmap

- `v0.2.0` — WebSocket streaming STT (`wss://api.x.ai/v1/stt`), interim
  results, per-channel multichannel streaming
- `v0.3.0` — Async helpers around `AVAudioEngine` taps for direct PCM streaming

## Contributing

Contributions welcome:

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Add tests
4. Ensure `swift test` passes
5. Submit a PR

### Development

```bash
swift build
swift test
```

### Guidelines

- Follow the existing brand-cased naming (`xAI…`)
- Keep zero external dependencies
- Maintain `Sendable` conformance under strict concurrency
- Add tests for new features and bug fixes
- Update `CHANGELOG.md`

## License

MIT — see [LICENSE](LICENSE) for details.

## Related

- [xAITTSKit](https://github.com/mrkhachaturov/xAITTSKit) — companion Text-to-Speech kit
