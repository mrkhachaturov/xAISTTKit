//
//  xAISTTLanguage.swift
//  Language codes accepted by xAI STT's `language` form field.
//  Source: https://docs.x.ai/docs/speech-to-text
//
//  Note: The model transcribes any of these languages regardless of this
//  parameter — passing it enables Inverse Text Normalization (formatting of
//  numbers, currencies, units) when combined with `format: true`.
//

import Foundation

public enum xAISTTLanguage: String, CaseIterable, Sendable {
    case ar         // Arabic
    case cs         // Czech
    case da         // Danish
    case nl         // Dutch
    case en         // English
    case fil        // Filipino
    case fr         // French
    case de         // German
    case hi         // Hindi
    case id         // Indonesian
    case it         // Italian
    case ja         // Japanese
    case ko         // Korean
    case mk         // Macedonian
    case ms         // Malay
    case fa         // Persian
    case pl         // Polish
    case pt         // Portuguese
    case ro         // Romanian
    case ru         // Russian
    case es         // Spanish
    case sv         // Swedish
    case th         // Thai
    case tr         // Turkish
    case vi         // Vietnamese
}

/// Raw audio format hint — only required for headerless audio (PCM / mulaw / alaw).
/// For container formats (MP3, WAV, OGG, Opus, FLAC, AAC, MP4, M4A, MKV) leave this nil.
public enum xAISTTAudioFormat: String, Sendable {
    case pcm        // 16-bit little-endian, 2 bytes/sample
    case mulaw      // G.711 μ-law, 1 byte/sample
    case alaw       // G.711 A-law, 1 byte/sample
}
