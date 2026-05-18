//
//  xAISTTError.swift
//

import Foundation

public enum xAISTTError: Error, LocalizedError, Sendable {
    case invalidURL
    case missingAuth
    case missingAudio
    case fileTooLarge(maxBytes: Int, gotBytes: Int)
    case http(status: Int, body: String?)
    case decoding(String)
    case formatRequiresLanguage
    case rawAudioRequiresSampleRate
    case canceled

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid xAI STT URL"
        case .missingAuth: return "Missing xAI Bearer token"
        case .missingAudio: return "No audio supplied: provide `audio` or `url`"
        case .fileTooLarge(let max, let got): return "Audio file too large: \(got)/\(max) bytes"
        case .http(let s, let body): return "xAI STT HTTP \(s): \(body ?? "<no body>")"
        case .decoding(let m): return "xAI STT decoding: \(m)"
        case .formatRequiresLanguage: return "format=true requires a `language` value"
        case .rawAudioRequiresSampleRate: return "Raw audio (pcm/mulaw/alaw) requires a `sampleRate`"
        case .canceled: return "xAI STT canceled"
        }
    }
}
