import Foundation
import Testing
@testable import xAISTTKit

@Suite struct xAISTTLanguageTests {
    @Test func twentyFiveLanguagesPresent() {
        // Spec: 25 ISO codes (no `auto` for STT).
        #expect(xAISTTLanguage.allCases.count == 25)
    }

    @Test func rawValuesMatchSpec() {
        #expect(xAISTTLanguage.en.rawValue == "en")
        #expect(xAISTTLanguage.fil.rawValue == "fil")
        #expect(xAISTTLanguage.fa.rawValue == "fa")
        #expect(xAISTTLanguage.mk.rawValue == "mk")
        #expect(xAISTTLanguage.ru.rawValue == "ru")
    }
}

@Suite struct xAISTTAudioFormatTests {
    @Test func rawAudioCodecRawValues() {
        #expect(xAISTTAudioFormat.pcm.rawValue == "pcm")
        #expect(xAISTTAudioFormat.mulaw.rawValue == "mulaw")
        #expect(xAISTTAudioFormat.alaw.rawValue == "alaw")
    }
}

@Suite struct xAISTTConfigurationTests {
    @Test func defaultsMatchSpec() {
        let cfg = xAISTTClient.Configuration(bearer: "test")
        #expect(cfg.baseURL.absoluteString == "https://api.x.ai/v1/stt")
        #expect(cfg.defaultLanguage == nil)
        #expect(cfg.timeoutSeconds == 120)
    }
}

@Suite struct xAISTTMultipartBodyTests {
    private let boundary = "----xai-test-boundary"

    @Test func bodyHeaderAndTrailerAreWellFormed() {
        let audio = Data([0x01, 0x02, 0x03])
        let body = xAISTTClient.encodeRequestBody(
            boundary: boundary,
            audio: audio,
            filename: "clip.wav",
            contentType: "audio/wav",
            language: .en,
            options: .init()
        )
        let body8 = String(data: body, encoding: .utf8) ?? ""
        // We expect the language field to appear as the first part
        #expect(body8.contains("--\(boundary)\r\n"))
        // Trailer
        #expect(body8.hasSuffix("--\(boundary)--\r\n"))
    }

    @Test func fileFieldIsLast() throws {
        // ASCII-safe payload so we can scan the body via String. Real uploads can
        // be arbitrary bytes; encodeRequestBody appends `audio` byte-for-byte.
        let audio = Data("AUDIO_PAYLOAD".utf8)
        let body = xAISTTClient.encodeRequestBody(
            boundary: boundary,
            audio: audio,
            filename: "x.wav",
            contentType: "audio/wav",
            language: .en,
            options: .init(format: true, keyTerms: ["one", "two"])
        )
        let body8 = try #require(String(data: body, encoding: .utf8))
        // Per the xAI spec, `file` must be the final field.
        let lastFieldStart = try #require(body8.range(of: "name=\"file\"", options: .backwards)).lowerBound
        let afterFile = body8[lastFieldStart...]
        #expect(afterFile.range(of: "name=\"language\"") == nil)
        #expect(afterFile.range(of: "name=\"format\"") == nil)
        #expect(afterFile.range(of: "name=\"keyterm\"") == nil)
    }

    @Test func repeatedKeytermFieldsEncodeEachTerm() {
        let body = xAISTTClient.encodeRequestBody(
            boundary: boundary,
            audio: Data([0]),
            filename: "a.mp3",
            contentType: "audio/mpeg",
            language: nil,
            options: .init(keyTerms: ["Grok", "xAI", "OpenClaw"])
        )
        let body8 = String(data: body, encoding: .utf8) ?? ""
        let occurrences = body8.components(separatedBy: "name=\"keyterm\"").count - 1
        #expect(occurrences == 3)
        #expect(body8.contains("Grok"))
        #expect(body8.contains("OpenClaw"))
    }

    @Test func urlFormFieldIsEmittedWhenNoFile() {
        let body = xAISTTClient.encodeRequestBody(
            boundary: boundary,
            audio: nil,
            filename: nil,
            contentType: nil,
            audioURL: URL(string: "https://example.com/clip.mp3")!,
            language: .en,
            options: .init()
        )
        let body8 = String(data: body, encoding: .utf8) ?? ""
        #expect(body8.contains("name=\"url\""))
        #expect(body8.contains("https://example.com/clip.mp3"))
        #expect(body8.contains("name=\"file\"") == false)
    }

    @Test func rawAudioFormatFields() {
        let body = xAISTTClient.encodeRequestBody(
            boundary: boundary,
            audio: Data([0]),
            filename: "raw.pcm",
            contentType: "application/octet-stream",
            language: .en,
            options: .init(audioFormat: .pcm, sampleRate: 16000)
        )
        let body8 = String(data: body, encoding: .utf8) ?? ""
        #expect(body8.contains("name=\"audio_format\""))
        #expect(body8.contains("pcm"))
        #expect(body8.contains("name=\"sample_rate\""))
        #expect(body8.contains("16000"))
    }
}

@Suite struct xAISTTWAVHeaderTests {
    @Test func headerEncodesRIFFAndDataLength() {
        let pcm = Data(repeating: 0x00, count: 320)   // 160 samples (mono PCM16)
        let wav = xAISTTClient.wrapAsWAV(pcm16: pcm, sampleRate: 16000)
        // Header is 44 bytes for canonical PCM WAV
        #expect(wav.count == 44 + pcm.count)
        let prefix = wav.prefix(4)
        #expect(prefix == Data("RIFF".utf8))
        // "WAVE" at bytes 8-11
        let wave = wav.subdata(in: 8..<12)
        #expect(wave == Data("WAVE".utf8))
        // "fmt " at 12-15, "data" at 36-39
        #expect(wav.subdata(in: 12..<16) == Data("fmt ".utf8))
        #expect(wav.subdata(in: 36..<40) == Data("data".utf8))
        // Sample rate (24-27) = 16000 LE
        let sr = wav.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        #expect(sr == 16000)
        // Bits per sample (34-35) = 16 LE
        let bps = wav.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        #expect(bps == 16)
    }
}

@Suite struct xAISTTResponseTests {
    @Test func decodesFullResponse() throws {
        let json = """
        {
          "text": "The balance is $167,983.15.",
          "language": "English",
          "duration": 3.45,
          "words": [
            { "text": "The", "start": 0.24, "end": 0.48 },
            { "text": "balance", "start": 0.48, "end": 0.96 }
          ]
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(xAISTTResponse.self, from: json)
        #expect(decoded.text == "The balance is $167,983.15.")
        #expect(decoded.language == "English")
        #expect(decoded.duration == 3.45)
        #expect(decoded.words?.count == 2)
        #expect(decoded.words?.first?.text == "The")
        #expect(decoded.words?.first?.speaker == nil)
    }

    @Test func decodesMinimalResponse() throws {
        let json = #"{"text":"hello"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(xAISTTResponse.self, from: json)
        #expect(decoded.text == "hello")
        #expect(decoded.language == nil)
        #expect(decoded.words == nil)
    }

    @Test func decodesMultichannelResponse() throws {
        let json = """
        {
          "text": "agent and customer transcript",
          "channels": [
            { "index": 0, "text": "agent speaking" },
            { "index": 1, "text": "customer speaking", "words": [{"text":"hi","start":0.0,"end":0.2}] }
          ]
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(xAISTTResponse.self, from: json)
        #expect(decoded.channels?.count == 2)
        #expect(decoded.channels?[1].words?.first?.text == "hi")
    }
}

@Suite struct xAISTTErrorTests {
    @Test func errorDescriptionsAreNonEmpty() {
        let cases: [xAISTTError] = [
            .invalidURL, .missingAuth, .missingAudio,
            .fileTooLarge(maxBytes: 500_000_000, gotBytes: 600_000_000),
            .http(status: 413, body: "too big"),
            .decoding("bad json"),
            .formatRequiresLanguage,
            .rawAudioRequiresSampleRate,
            .canceled
        ]
        for err in cases {
            #expect((err.errorDescription ?? "").isEmpty == false)
        }
    }
}
