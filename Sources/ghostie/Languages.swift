import Foundation

/// One language the user has told Ghostie to understand, together with
/// everything that is *per-language* about it.
///
/// This is the v3 replacement for the three parallel maps that used to encode
/// the same thing (`codeSwitch.languages: [String]` +
/// `codeSwitch.modelPerLanguage` + `codeSwitch.prompts`). Keeping them together
/// means adding a language is one edit in one place, and no code path can see a
/// language that has a prompt but no model, or vice versa.
///
/// `model` is a **catalog filename** (`ggml-large-v3-q5_0.bin`) — the same key
/// `ModelCatalog`, `ModelDownloader` and the `.meta` sidecar use — so there is
/// one namespace for "which file". An absolute path or a pre-v3 logical name
/// (`kb-whisper-large`) still resolves, for hand-edited configs and migrations.
/// `nil` means "whatever is the best installed model for this language", which
/// is what almost every entry should say.
struct LanguageSetting: Codable, Equatable, ExpressibleByStringLiteral {
    /// ISO-639-1 code, lowercased. The label the LID emits and the pipeline
    /// routes on.
    var code: String
    /// Catalog filename / absolute path / legacy logical name. nil = auto-pick.
    var model: String?
    /// Decoder prompt for this language. nil = fall back to the built-in
    /// default (see `LanguageDefaults`); "" = deliberately no prompt.
    var prompt: String?

    init(code: String, model: String? = nil, prompt: String? = nil) {
        self.code = code.trimmingCharacters(in: .whitespaces).lowercased()
        self.model = model
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey { case code, model, prompt }

    /// Decodes both the v3 object form *and* the pre-v3 bare string, so a
    /// legacy `"languages": ["sv", "en"]` migrates by simply being decoded —
    /// no separate legacy container, no version field. Missing keys fall back
    /// to defaults (the same trap that bit `Config`: synthesized `Decodable`
    /// throws on any absent key, and `loadRaw()`'s `try?` would swallow it into
    /// a whole-config reset).
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let bare = try? single.decode(String.self) {
            self.init(code: bare)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawCode = ((try? c.decodeIfPresent(String.self, forKey: .code)) ?? nil) ?? ""
        self.init(code: rawCode,
                  model: (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil,
                  prompt: (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? nil)
    }

    /// `"sv"` builds an auto-everything record. A bare code really is the whole
    /// setting for most languages, and this keeps call sites (and the JSON
    /// migration path, which decodes the same shape) reading as a plain list.
    init(stringLiteral value: String) { self.init(code: value) }

    /// Hand-written so nil fields are *omitted* rather than written as `null` —
    /// `config.json` is a file people read and edit, and a wall of nulls is
    /// noise. (Synthesized encoding of Optionals is not guaranteed to skip.)
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(prompt, forKey: .prompt)
    }
}

/// Built-in per-language defaults. These are *defaults*, not user config: they
/// apply until a `LanguageSetting` carries an explicit value, and they are
/// never written to `config.json`. Pre-v3 they lived in
/// `CodeSwitchConfig.prompts`, which meant a fresh config file was born with
/// two Swedish/English prompts in it whether or not the user spoke either.
enum LanguageDefaults {

    /// Decoder prompts shipped for the languages Ghostie was built against.
    /// A language with no entry gets no `--prompt` arg at all (rather than
    /// being nudged toward the wrong domain, which is what the pre-v2
    /// `lang == "sv" ? promptSv : promptEn` fallback did).
    static let prompts: [String: String] = [
        "sv": "Affärssamtal på svenska. Termer: Ingka, Xplore, IKEA, IFB.",
        "en": "Business call in English. Terms: Ingka, Xplore, IKEA, IFB, MCP, ACP."
    ]

    static func prompt(for code: String) -> String { prompts[code] ?? "" }
}

/// The languages Whisper can label audio with. This is the picker's source —
/// the point being that a user chooses "German" from a list instead of typing
/// `de` into a free-text field and discovering months later that `ger` is never
/// emitted by the LID and so their model was never once used.
///
/// Codes and names track whisper.cpp's `g_lang` table (the same set the
/// `--detect-language` head can return). Display names prefer the system
/// locale's own translation and fall back to the English name here.
enum WhisperLanguages {

    /// (code, English name), in whisper.cpp's table order.
    static let all: [(code: String, name: String)] = [
        ("en", "English"), ("zh", "Chinese"), ("de", "German"), ("es", "Spanish"),
        ("ru", "Russian"), ("ko", "Korean"), ("fr", "French"), ("ja", "Japanese"),
        ("pt", "Portuguese"), ("tr", "Turkish"), ("pl", "Polish"), ("ca", "Catalan"),
        ("nl", "Dutch"), ("ar", "Arabic"), ("sv", "Swedish"), ("it", "Italian"),
        ("id", "Indonesian"), ("hi", "Hindi"), ("fi", "Finnish"), ("vi", "Vietnamese"),
        ("he", "Hebrew"), ("uk", "Ukrainian"), ("el", "Greek"), ("ms", "Malay"),
        ("cs", "Czech"), ("ro", "Romanian"), ("da", "Danish"), ("hu", "Hungarian"),
        ("ta", "Tamil"), ("no", "Norwegian"), ("th", "Thai"), ("ur", "Urdu"),
        ("hr", "Croatian"), ("bg", "Bulgarian"), ("lt", "Lithuanian"), ("la", "Latin"),
        ("mi", "Maori"), ("ml", "Malayalam"), ("cy", "Welsh"), ("sk", "Slovak"),
        ("te", "Telugu"), ("fa", "Persian"), ("lv", "Latvian"), ("bn", "Bengali"),
        ("sr", "Serbian"), ("az", "Azerbaijani"), ("sl", "Slovenian"), ("kn", "Kannada"),
        ("et", "Estonian"), ("mk", "Macedonian"), ("br", "Breton"), ("eu", "Basque"),
        ("is", "Icelandic"), ("hy", "Armenian"), ("ne", "Nepali"), ("mn", "Mongolian"),
        ("bs", "Bosnian"), ("kk", "Kazakh"), ("sq", "Albanian"), ("sw", "Swahili"),
        ("gl", "Galician"), ("mr", "Marathi"), ("pa", "Punjabi"), ("si", "Sinhala"),
        ("km", "Khmer"), ("sn", "Shona"), ("yo", "Yoruba"), ("so", "Somali"),
        ("af", "Afrikaans"), ("oc", "Occitan"), ("ka", "Georgian"), ("be", "Belarusian"),
        ("tg", "Tajik"), ("sd", "Sindhi"), ("gu", "Gujarati"), ("am", "Amharic"),
        ("yi", "Yiddish"), ("lo", "Lao"), ("uz", "Uzbek"), ("fo", "Faroese"),
        ("ht", "Haitian Creole"), ("ps", "Pashto"), ("tk", "Turkmen"), ("nn", "Nynorsk"),
        ("mt", "Maltese"), ("sa", "Sanskrit"), ("lb", "Luxembourgish"), ("my", "Burmese"),
        ("bo", "Tibetan"), ("tl", "Tagalog"), ("mg", "Malagasy"), ("as", "Assamese"),
        ("tt", "Tatar"), ("haw", "Hawaiian"), ("ln", "Lingala"), ("ha", "Hausa"),
        ("ba", "Bashkir"), ("jw", "Javanese"), ("su", "Sundanese"), ("yue", "Cantonese")
    ]

    /// The languages Ghostie is most often asked for, offered at the top of the
    /// picker ahead of the alphabetical run of 99. Not a capability list —
    /// every language in `all` works identically; this is purely about not
    /// making someone scroll past Sinhala and Slovak to reach Swedish.
    static let common = ["sv", "en", "de", "es"]

    private static let namesByCode: [String: String] =
        Dictionary(all.map { ($0.code, $0.name) }, uniquingKeysWith: { a, _ in a })

    /// True when Whisper can actually emit this label. The picker only offers
    /// these; `isSupported` additionally guards a hand-edited config.
    static func isSupported(_ code: String) -> Bool {
        namesByCode[code.lowercased()] != nil
    }

    /// Human name for a code. Prefers the user's own locale ("Tyska" for a
    /// Swedish system), falls back to the English table, then to the raw code
    /// so a hand-edited unknown label still renders as something.
    static func displayName(_ code: String) -> String {
        let lc = code.lowercased()
        if let localized = Locale.current.localizedString(forLanguageCode: lc),
           // Locale echoes the code back for identifiers it doesn't know; that
           // is not a translation, so prefer our own table in that case.
           localized.lowercased() != lc {
            return localized
        }
        return namesByCode[lc] ?? code
    }

    /// "German · de" — the label used in lists and pickers.
    static func label(_ code: String) -> String { "\(displayName(code)) · \(code)" }

    /// Every language, sorted by display name in the user's locale — the order
    /// the picker lists them in below the suggestions.
    static func allSortedByName() -> [(code: String, name: String)] {
        all.map { (code: $0.code, name: displayName($0.code)) }
           .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
