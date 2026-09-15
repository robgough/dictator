import Foundation

/// A language a mode can be told to listen in, or to write out in.
///
/// Two separate settings use this, and they do different jobs:
///
/// - **Spoken language** is a *hint to the recogniser*. Both engines
///   auto-detect, and both get better when told: Whisper skips its
///   language-detection pass and decodes with the right token set; Parakeet v3
///   filters decoder candidates to the language's script, which is what stops
///   a Polish dictation coming back peppered with Cyrillic.
/// - **Output language** is a *translation target*. Neither ASR engine can be
///   asked for a language other than the one being spoken (Whisper's own
///   translate task only ever produces English), so translation happens in a
///   final LLM pass instead — which also means it works for any pair the local
///   model knows, not just "→ English".
///
/// The case list is curated rather than exhaustive. Whisper nominally claims
/// 99 languages; most of the tail is unusable for dictation, and a 99-item
/// picker is worse than a 30-item one.
public enum DictationLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Let the engine work it out (and, as an output language, don't
    /// translate at all). The default everywhere.
    case auto

    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case catalan = "ca"
    case swedish = "sv"
    case danish = "da"
    case norwegian = "no"
    case finnish = "fi"
    case polish = "pl"
    case czech = "cs"
    case slovak = "sk"
    case slovenian = "sl"
    case croatian = "hr"
    case romanian = "ro"
    case hungarian = "hu"
    case bulgarian = "bg"
    case greek = "el"
    case russian = "ru"
    case ukrainian = "uk"
    case turkish = "tr"
    case arabic = "ar"
    case hebrew = "he"
    case hindi = "hi"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh"
    case vietnamese = "vi"
    case thai = "th"
    case indonesian = "id"
    case malay = "ms"

    public var id: String { rawValue }

    /// Name for pickers, in the language's own terms where that's what people
    /// expect to see, English otherwise.
    public var label: String {
        switch self {
        case .auto:       return "Automatic"
        case .english:    return "English"
        case .spanish:    return "Spanish"
        case .french:     return "French"
        case .german:     return "German"
        case .italian:    return "Italian"
        case .portuguese: return "Portuguese"
        case .dutch:      return "Dutch"
        case .catalan:    return "Catalan"
        case .swedish:    return "Swedish"
        case .danish:     return "Danish"
        case .norwegian:  return "Norwegian"
        case .finnish:    return "Finnish"
        case .polish:     return "Polish"
        case .czech:      return "Czech"
        case .slovak:     return "Slovak"
        case .slovenian:  return "Slovenian"
        case .croatian:   return "Croatian"
        case .romanian:   return "Romanian"
        case .hungarian:  return "Hungarian"
        case .bulgarian:  return "Bulgarian"
        case .greek:      return "Greek"
        case .russian:    return "Russian"
        case .ukrainian:  return "Ukrainian"
        case .turkish:    return "Turkish"
        case .arabic:     return "Arabic"
        case .hebrew:     return "Hebrew"
        case .hindi:      return "Hindi"
        case .japanese:   return "Japanese"
        case .korean:     return "Korean"
        case .chinese:    return "Chinese"
        case .vietnamese: return "Vietnamese"
        case .thai:       return "Thai"
        case .indonesian: return "Indonesian"
        case .malay:      return "Malay"
        }
    }

    /// The ISO code to hand an ASR engine, or nil for `.auto`.
    public var asrCode: String? {
        self == .auto ? nil : rawValue
    }

    /// Everything except `.auto`, for pickers that want the real languages.
    public static var selectable: [DictationLanguage] {
        allCases.filter { $0 != .auto }
    }

    /// Languages whose Parakeet support is a script hint rather than genuine
    /// recognition. Parakeet v3 covers 25 European languages; ask it for
    /// Japanese and you get transliterated nonsense, so the mode editor warns
    /// when the active engine can't actually hear the chosen language.
    ///
    /// Whisper covers all of these, so the warning is Parakeet-only.
    public var isParakeetSupported: Bool {
        switch self {
        case .auto, .english, .spanish, .french, .german, .italian, .portuguese,
             .dutch, .catalan, .swedish, .danish, .norwegian, .finnish, .polish,
             .czech, .slovak, .slovenian, .croatian, .romanian, .hungarian,
             .bulgarian, .greek, .russian, .ukrainian:
            return true
        case .turkish, .arabic, .hebrew, .hindi, .japanese, .korean, .chinese,
             .vietnamese, .thai, .indonesian, .malay:
            return false
        }
    }
}
