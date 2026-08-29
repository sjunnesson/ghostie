import Foundation

/// Turns placeholder speaker labels into the names people actually use.
///
/// Diarization can tell voices apart but has no idea who they belong to. The
/// names are almost always right there in the conversation — people greet each
/// other, introduce themselves, hand over by name — so this asks the
/// already-configured summarization model to read them off, the same way a
/// person skimming the transcript would.
///
/// Every failure path keeps the placeholder: no provider, an unparseable
/// reply, a name that looks like a job title or a sentence, a model that
/// invented someone. A transcript labelled "Participant 1" is honest; one
/// labelled with the wrong name is worse than useless, because a summary built
/// on it attributes decisions to people who never made them.
struct SpeakerNamer {

    let config: Config

    /// Names are short. Anything longer is the model explaining itself rather
    /// than answering, and gets dropped.
    static let maxNameLength = 40
    /// Floor on how much transcript to show; the provider's own
    /// `maxTranscriptChars` is used when it is larger. Names surface early
    /// (greetings) and at hand-offs, so when the budget does bind, the head of
    /// the call is the part worth keeping.
    ///
    /// This used to be a flat 24 000 for every provider, which on the
    /// 2026-08-28 call cut the transcript in half and left exactly one mention
    /// of one participant's name inside the window — the model was guessing
    /// from almost nothing. The whole transcript already goes to this same
    /// provider for the summary, so showing all of it here exposes nothing new.
    static let promptBudget = 24_000

    struct Naming {
        /// label → display name, only for labels that got a real name.
        let names: [String: String]
        var summary: String {
            names.isEmpty
                ? "speaker naming: no names established — keeping generic labels"
                : "speaker naming: " + names.sorted { $0.key < $1.key }
                    .map { "\($0.key) → \($0.value)" }.joined(separator: ", ")
        }
    }

    /// Maps `labels` onto real names. Returns nil when naming is off or
    /// unavailable, which leaves every label untouched.
    func name(labels: [String], transcript: String) -> Naming? {
        guard config.nameSpeakers, !labels.isEmpty else { return nil }

        // A configured name for the local speaker is a fact, not a guess — it
        // is applied whether or not the model can be reached.
        var resolved: [String: String] = [:]
        var ask = labels
        if !config.userName.isEmpty, let me = labels.first(where: { $0 == "Me" }) {
            resolved[me] = config.userName.trimmingCharacters(in: .whitespaces)
            ask.removeAll { $0 == me }
        }
        guard !ask.isEmpty else { return Naming(names: resolved) }

        let provider = Summarizer(config: config).provider
        guard provider.isConfigured else {
            return resolved.isEmpty ? nil : Naming(names: resolved)
        }
        guard let reply = try? provider.complete(
                system: Self.system,
                user: Self.user(labels: ask, transcript: transcript,
                                knownSelf: resolved["Me"],
                                budget: max(Self.promptBudget,
                                            provider.maxTranscriptChars))) else {
            Log.info("Speaker naming skipped: the summarization model could not be reached.")
            return resolved.isEmpty ? nil : Naming(names: resolved)
        }
        let spoken = Self.spokenWords(transcript)
        for (label, name) in Self.parse(reply, labels: ask) {
            guard Self.isSpoken(name, in: spoken) else {
                Log.info("Speaker naming: dropped \"\(name)\" for \(label) — that name is "
                    + "never spoken in the transcript.")
                continue
            }
            resolved[label] = name
        }
        let (deduped, dropped) = Self.resolveCollisions(
            resolved, facts: resolved["Me"] != nil && !config.userName.isEmpty ? ["Me"] : [])
        if !dropped.isEmpty {
            Log.warn("Speaker naming: \(dropped.sorted().joined(separator: ", ")) "
                + "came back sharing a name with another speaker — keeping the generic "
                + "label(s), because a name on the wrong voice corrupts the summary built on it.")
        }
        return Naming(names: deduped)
    }

    /// Every distinct word in the transcript, folded for comparison. Built
    /// once per call because `isSpoken` is asked about every label.
    static func spokenWords(_ transcript: String) -> Set<String> {
        var out: Set<String> = []
        var current = ""
        for ch in transcript.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                     locale: nil) {
            if ch.isLetter || ch.isNumber { current.append(ch) }
            else if !current.isEmpty { out.insert(current); current = "" }
        }
        if !current.isEmpty { out.insert(current) }
        return out
    }

    /// Whether a name is one the transcript actually contains.
    ///
    /// The rules already tell the model to take names only from people
    /// addressing each other or introducing themselves, which means the name
    /// has to be *in the text*. A name that isn't was invented — from the
    /// topic, the company, or a plausible-sounding guess — and no other guard
    /// here catches that.
    ///
    /// What it deliberately does **not** do is adjudicate spelling. When
    /// whisper writes one spoken name two ways — the 2026-08-28 call has both
    /// "Paula" (5×) and "Paola" (4×) for the same person — both are genuinely
    /// in the transcript and this has no basis for preferring either. Fixing
    /// that needs a source of truth outside the audio, e.g. the meeting
    /// roster; don't reach for a fuzzy match here, which would just as happily
    /// merge two people with similar names.
    ///
    /// Only the first token has to appear: people are addressed by first name
    /// and the model may reasonably return "David Sjunnesson" from a signature
    /// or a calendar-style introduction. Comparison ignores case and
    /// diacritics, so a transcript's "José" accepts "Jose". Static + pure for
    /// the self-test.
    static func isSpoken(_ name: String, in spoken: Set<String>) -> Bool {
        guard let first = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first
        else { return false }
        return spoken.contains(String(first).folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: nil))
    }

    /// Drops any name the model handed to more than one label.
    ///
    /// Diarization splitting two people apart is the hard-won part, and it is
    /// usually right: on the 2026-08-28 call its clusters matched the meeting
    /// roster 77% and 69% of the time. When the naming pass then puts one name
    /// on both, that distinction is erased and every word either person said
    /// is attributed to whoever got the name — on that call the merged label
    /// matched *neither* speaker (54% one, 27% the other, 13% a third).
    ///
    /// There is no way to tell which label the name was meant for, and picking
    /// the talkative one is not a tiebreak — it would have been wrong on
    /// exactly that call, where the larger cluster was the *other* person. So
    /// every label in a collision keeps its placeholder. A transcript labelled
    /// "Participant 1" is honest; one that merges two people under a single
    /// name is not, and nothing downstream can tell.
    ///
    /// A name from config (`userName`) is a fact rather than a guess, so it
    /// survives and only the guesses colliding with it are dropped.
    /// Comparison ignores case and diacritics, so "José"/"Jose" collide.
    /// Static + pure for the self-test.
    static func resolveCollisions(_ names: [String: String], facts: Set<String>)
        -> (names: [String: String], dropped: [String]) {
        var byName: [String: [String]] = [:]
        for (label, name) in names {
            let key = name.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: nil)
                .trimmingCharacters(in: .whitespaces)
            byName[key, default: []].append(label)
        }
        var out = names
        var dropped: [String] = []
        for (_, labels) in byName where labels.count > 1 {
            let fact = labels.filter { facts.contains($0) }
            // Exactly one fact keeps its name; zero facts (or a fact colliding
            // with another fact, which config cannot produce today) drops all.
            let survivors = fact.count == 1 ? Set(fact) : Set<String>()
            for label in labels where !survivors.contains(label) {
                out[label] = nil
                dropped.append(label)
            }
        }
        return (out, dropped)
    }

    // MARK: - Prompt

    static let system = """
    You identify speakers in a meeting transcript.

    You are given a transcript whose speakers are placeholder labels, and the \
    list of labels to identify. Work out what each speaker is actually called, \
    using only evidence in the transcript: how people greet each other, \
    introduce themselves, sign off, or address one another by name.

    Reply with ONLY a JSON object mapping each label to a name. No prose, no \
    code fence, no explanation.

    Rules:
    - Use "" for any speaker whose name is not established in the transcript. \
      An empty string is the correct, expected answer — guessing is not.
    - A name is what a person is called: "Agneta", "David Sjunnesson". Never a \
      role or description ("the advisor", "the client", "Speaker 2").
    - Never infer a name from the topic, the company, or who is being \
      discussed. Only from who is being addressed or who introduces themselves.
    - People mentioned but not speaking must not be assigned to a label.
    - Each label is a different voice. Never give the same name to two \
      labels. If you cannot tell which of two labels a name belongs to, put \
      it on neither — use "" for both.

    Example reply: {"Me": "David", "Participant 1": "Agneta", "Participant 2": ""}
    """

    static func user(labels: [String], transcript: String, knownSelf: String?,
                     budget: Int = promptBudget) -> String {
        var head = transcript
        if head.count > budget { head = String(head.prefix(budget)) }
        var s = "Labels to identify: \(labels.joined(separator: ", "))\n"
        if let knownSelf {
            s += "\nAlready known: the local speaker (\"Me\") is \(knownSelf).\n"
        }
        s += "\nTranscript:\n\n\(head)"
        return s
    }

    // MARK: - Parsing

    /// Pulls the JSON object out of a reply and keeps only names that look
    /// like names, for labels that were actually asked about.
    ///
    /// Internal for the self-test.
    static func parse(_ reply: String, labels: [String]) -> [String: String] {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"), start < end else { return [:] }
        let json = String(reply[start...end])
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        let wanted = Set(labels)
        var out: [String: String] = [:]
        for (label, value) in raw {
            guard wanted.contains(label), let name = value as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPlausibleName(trimmed) else { continue }
            out[label] = trimmed
        }
        return out
    }

    /// A name, not a sentence and not a role. Deliberately strict: the cost of
    /// rejecting a real name is a generic label, and the cost of accepting a
    /// hallucinated one is a transcript that lies about who said what.
    static func isPlausibleName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= maxNameLength else { return false }
        // At most a first name plus a couple of further parts.
        let parts = s.split(separator: " ")
        guard (1...4).contains(parts.count) else { return false }
        // No punctuation that belongs to prose.
        guard s.rangeOfCharacter(from: CharacterSet(charactersIn: ".,:;!?\"'()[]{}<>/\\|@#$%^&*=+")) == nil
        else { return false }
        // Must start with a letter, and contain no digits anywhere — "Speaker
        // 2" and "Participant 1" are exactly what we are replacing.
        guard let first = s.first, first.isLetter else { return false }
        guard s.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        // Reject the role words a model reaches for when it has no name.
        let lowered = s.lowercased()
        let roles: Set<String> = [
            "me", "you", "unknown", "speaker", "participant", "participants",
            "host", "guest", "caller", "client", "customer", "advisor",
            "interviewer", "interviewee", "agent", "user", "the advisor",
            "the client", "the host", "the caller", "n/a", "none", "null"
        ]
        return !roles.contains(lowered)
    }
}
