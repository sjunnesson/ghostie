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
    /// How much transcript to show. Names surface early (greetings) and at
    /// hand-offs, so the head of the call is worth more than the middle.
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
                                knownSelf: resolved["Me"])) else {
            Log.info("Speaker naming skipped: the summarization model could not be reached.")
            return resolved.isEmpty ? nil : Naming(names: resolved)
        }
        for (label, name) in Self.parse(reply, labels: ask) { resolved[label] = name }
        return Naming(names: resolved)
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
    - Two labels may share a name if the transcript makes clear they are one \
      person split in two.

    Example reply: {"Me": "David", "Participant 1": "Agneta", "Participant 2": ""}
    """

    static func user(labels: [String], transcript: String, knownSelf: String?) -> String {
        var head = transcript
        if head.count > promptBudget { head = String(head.prefix(promptBudget)) }
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
