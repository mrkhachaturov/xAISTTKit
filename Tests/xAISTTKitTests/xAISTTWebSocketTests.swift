import Foundation
import Testing
@testable import xAISTTKit

@Suite struct xAISTTWebSocketURLTests {
    @Test func defaultsMatchSpec() {
        let config = xAISTTWebSocketSession.Configuration(bearer: "test")
        let url = config.makeURL()
        let dict = Self.queryDict(url)
        #expect(url.scheme == "wss")
        #expect(url.host == "api.x.ai")
        #expect(url.path == "/v1/stt")
        // Required: sample_rate + encoding always emitted.
        #expect(dict["sample_rate"] == "16000")
        #expect(dict["encoding"] == "pcm")
        // Nothing else when defaults are used.
        #expect(dict.keys.contains("language") == false)
        #expect(dict.keys.contains("interim_results") == false)
    }

    @Test func emitsAllOptionalFields() {
        let config = xAISTTWebSocketSession.Configuration(
            bearer: "test",
            encoding: .mulaw,
            sampleRate: 8000,
            language: .en,
            interimResults: true,
            endpointingMs: 250,
            diarize: true,
            fillerWords: true,
            multichannel: true,
            channels: 2,
            keyTerms: ["Grok", "xAI"]
        )
        let url = config.makeURL()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let dict = Dictionary(grouping: items, by: \.name)
        #expect(dict["encoding"]?.first?.value == "mulaw")
        #expect(dict["sample_rate"]?.first?.value == "8000")
        #expect(dict["language"]?.first?.value == "en")
        #expect(dict["interim_results"]?.first?.value == "true")
        #expect(dict["endpointing"]?.first?.value == "250")
        #expect(dict["diarize"]?.first?.value == "true")
        #expect(dict["filler_words"]?.first?.value == "true")
        #expect(dict["multichannel"]?.first?.value == "true")
        #expect(dict["channels"]?.first?.value == "2")
        // keyterm appears once per term
        #expect(dict["keyterm"]?.count == 2)
        let keytermValues = dict["keyterm"]?.compactMap(\.value).sorted() ?? []
        #expect(keytermValues == ["Grok", "xAI"])
    }

    private static func queryDict(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let v = item.value else { return nil }
            return (item.name, v)
        })
    }
}

@Suite struct xAISTTWebSocketAuthTests {
    @Test func usesSecWebSocketProtocolFormat() {
        #expect(xAISTTWebSocketSession.authProtocol(bearer: "sk-xai-abc") == "xai-client-secret.sk-xai-abc")
    }
}

@Suite struct xAISTTWebSocketFrameEncodingTests {
    @Test func audioDoneFrame() throws {
        let json = try JSONSerialization.jsonObject(with: Data(xAISTTWebSocketSession.audioDoneFrame.utf8)) as! [String: Any]
        #expect(json["type"] as? String == "audio.done")
        #expect(json.count == 1)
    }
}

@Suite struct xAISTTWebSocketEventDecodingTests {
    @Test func decodesTranscriptCreatedAsReady() {
        #expect(xAISTTWebSocketSession.decodeServerEvent(text: #"{"type":"transcript.created"}"#) == .ready)
    }

    @Test func decodesInterimPartial() {
        let frame = """
        {"type":"transcript.partial","text":"hello world","is_final":false,"speech_final":false,"start":0.0,"duration":1.2}
        """
        guard case let .partial(t) = xAISTTWebSocketSession.decodeServerEvent(text: frame)! else {
            Issue.record("expected .partial")
            return
        }
        #expect(t.text == "hello world")
        #expect(t.isFinal == false)
        #expect(t.speechFinal == false)
        #expect(t.start == 0.0)
        #expect(t.duration == 1.2)
        #expect(t.channelIndex == nil)
    }

    @Test func decodesChunkFinalPartial() {
        let frame = #"{"type":"transcript.partial","text":"chunk","is_final":true,"speech_final":false}"#
        guard case let .partial(t) = xAISTTWebSocketSession.decodeServerEvent(text: frame)! else {
            Issue.record("expected .partial")
            return
        }
        #expect(t.isFinal == true)
        #expect(t.speechFinal == false)
    }

    @Test func decodesUtteranceFinalPartial() {
        let frame = #"{"type":"transcript.partial","text":"utterance","is_final":true,"speech_final":true}"#
        guard case let .partial(t) = xAISTTWebSocketSession.decodeServerEvent(text: frame)! else {
            Issue.record("expected .partial")
            return
        }
        #expect(t.isFinal == true)
        #expect(t.speechFinal == true)
    }

    @Test func decodesTranscriptDoneWithWordsAndChannel() {
        let frame = """
        {"type":"transcript.done","text":"done text","duration":3.45,"channel_index":1,
         "words":[{"text":"done","start":0.1,"end":0.5},{"text":"text","start":0.5,"end":0.9}]}
        """
        guard case let .done(t) = xAISTTWebSocketSession.decodeServerEvent(text: frame)! else {
            Issue.record("expected .done")
            return
        }
        #expect(t.text == "done text")
        #expect(t.duration == 3.45)
        #expect(t.channelIndex == 1)
        #expect(t.words?.count == 2)
        #expect(t.words?.first?.text == "done")
        #expect(t.isFinal == true)
        #expect(t.speechFinal == true)
    }

    @Test func decodesError() {
        let frame = #"{"type":"error","message":"audio too quiet"}"#
        #expect(xAISTTWebSocketSession.decodeServerEvent(text: frame) == .error(message: "audio too quiet"))
    }

    @Test func rejectsMalformed() {
        #expect(xAISTTWebSocketSession.decodeServerEvent(text: "not json") == nil)
        #expect(xAISTTWebSocketSession.decodeServerEvent(text: "{}") == nil)
        #expect(xAISTTWebSocketSession.decodeServerEvent(text: #"{"type":"unknown"}"#) == nil)
    }
}
