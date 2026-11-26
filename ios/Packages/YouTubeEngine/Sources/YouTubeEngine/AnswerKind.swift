import Foundation

/// What a `/player` answer means for the source walk (LANES §2.2). The lane-dependent decisions
/// (whether a refusal admits anonymous TV_TIZEN, when an age gate settles, consensus) belong to the
/// planner (US-015); this is the per-answer verdict, ported from Android's `VideoInfo` predicates
/// and `BotCheckDetector`.
public enum AnswerKind: Sendable, Equatable {
    /// A playable delivery: adaptive formats with URLs (or ciphers the solver can open).
    case served
    /// Live and playable, but no DASH manifest: held, and only live-DASH sources asked after it.
    case liveWithoutDash
    /// UNPLAYABLE without a terminal verdict (made-for-kids on VISIONOS, a region, an embed policy).
    case contentRefused
    /// An age gate: the structured marker or an AGE_* status.
    case ageGate
    /// LOGIN_REQUIRED without the age marker or bot text (private, shared, or a bot wall in another
    /// language: the walk's repeated-reason rule tells those apart).
    case signInRequest
    /// LOGIN_REQUIRED with "bot", "robot" or "captcha" in the reason.
    case botChallenge
    /// OK but nothing to fetch (SABR-only, or no adaptive formats).
    case noDelivery
    /// Terminal for the content whichever client asks; settles on consensus (US-015). The key is
    /// Android's: `removed-by-uploader`, `account-terminated`, `removed-for-violation`,
    /// `live-recording-gone`, `members-only`.
    case terminal(String)
    /// ERROR, LIVE_STREAM_OFFLINE, CONTENT_CHECK_REQUIRED and anything else.
    case unavailable(String)

    public init(_ answer: PlayerAnswer) {
        let status = answer.playability.status
        let reason = answer.playability.text
        switch status {
        case "OK":
            if answer.isLive && answer.dashManifestURL == nil && !answer.hasAdaptiveDelivery {
                self = answer.hlsManifestURL != nil ? .liveWithoutDash : .noDelivery
            } else if answer.hasAdaptiveDelivery {
                self = answer.isLive && answer.dashManifestURL == nil ? .liveWithoutDash : .served
            } else {
                self = .noDelivery
            }
        case "AGE_CHECK_REQUIRED", "AGE_VERIFICATION_REQUIRED":
            self = .ageGate
        case "LOGIN_REQUIRED":
            if answer.playability.desktopLegacyAgeGateReason != 0 {
                self = .ageGate
            } else if Self.isExplicitBotCheck(status: status, reason: reason) {
                self = .botChallenge
            } else {
                self = .signInRequest
            }
        case "UNPLAYABLE", "ERROR":
            if let key = Self.terminalKey(status: status, reason: reason) {
                self = .terminal(key)
            } else {
                self = status == "UNPLAYABLE" ? .contentRefused : .unavailable(status)
            }
        default:
            self = .unavailable(status)
        }
    }

    /// `log` field: `served`, `terminal:members-only`, …
    public var logValue: String {
        switch self {
        case .served: "served"
        case .liveWithoutDash: "live-no-dash"
        case .contentRefused: "content-refused"
        case .ageGate: "age-gate"
        case .signInRequest: "sign-in"
        case .botChallenge: "bot-check"
        case .noDelivery: "no-delivery"
        case .terminal(let key): "terminal:\(key)"
        case .unavailable(let status): "unavailable:\(status)"
        }
    }

    // MARK: BotCheckDetector (MediaServiceCore 52fecea0), ported

    static func isExplicitBotCheck(status: String?, reason: String?) -> Bool {
        guard status == "LOGIN_REQUIRED", let reason else { return false }
        let normalized = normalize(reason)
        return normalized.contains("bot") || normalized.contains("robot") || normalized.contains("captcha")
    }

    /// `definitiveUnplayableKey`: an allowlist of whole sentences in six locales, members-only
    /// openings, and policy-violation removals that name no device/site/app/embed and carry only
    /// "learn more" tails; any region hint in the verdict vetoes it. A miss only costs requests.
    static func terminalKey(status: String?, reason: String?) -> String? {
        guard status == "UNPLAYABLE" || status == "ERROR", let reason else { return nil }
        let canonical = canonicalReason(reason)
        let sentences = canonical.components(separatedBy: ". ")
        let verdict = canonicalReason(sentences[0])
        if regionHints.contains(where: verdict.contains) { return nil }
        if let key = terminalReasons[canonical] { return key }
        if status == "UNPLAYABLE", membersOnlyOpenings.contains(where: verdict.hasPrefix) { return "members-only" }
        return isViolationRemoval(verdict: verdict, sentences: sentences) ? "removed-for-violation" : nil
    }

    private static func isViolationRemoval(verdict: String, sentences: [String]) -> Bool {
        guard violationRemovals.contains(where: verdict.hasPrefix) else { return false }
        if violationQualifiers.contains(where: verdict.contains) { return false }
        return sentences.dropFirst().allSatisfy { sentence in learnMore.contains(where: sentence.hasPrefix) }
    }

    /// Accents, case and runs of whitespace dropped (Java's NFD + `\p{M}` strip).
    static func normalize(_ value: String) -> String {
        let stripped = value.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !CharacterSet.nonBaseCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(stripped))
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Normalized, curly apostrophes folded, surrounding quotes and trailing punctuation stripped.
    static func canonicalReason(_ reason: String) -> String {
        var value = Array(normalize(reason).replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'"))
        let trailing = Set(".!?\"'\u{201D}\u{00BB}\u{2026} ")
        let leading = Set("\"'\u{201C}\u{00AB} ")
        while let last = value.last, trailing.contains(last) { value.removeLast() }
        while let first = value.first, leading.contains(first) { value.removeFirst() }
        return String(value)
    }

    private static let regionHints = ["country", "pais", "pays", "land", "paese", "region"]

    private static let membersOnlyOpenings = [
        "join this channel", "hazte miembro de este canal", "unete a este canal", "devenez membre de cette chaine",
        "rejoignez cette chaine", "werde mitglied dieses kanals", "werde kanalmitglied",
        "diventa membro di questo canale", "abbonati a questo canale", "seja membro deste canal",
        "torne-se membro deste canal",
    ]

    private static let violationRemovals = [
        "this video has been removed for violating youtube's", "este video se ha retirado por infringir",
        "este video se ha retirado porque infringia", "este video se ha eliminado por infringir",
        "cette video a ete supprimee, car elle ne respectait pas", "dieses video wurde entfernt, weil es gegen",
        "questo video e stato rimosso per violazione", "este video foi removido por violar",
    ]

    private static let violationQualifiers = [
        "device", "site", "app", "embed", "player", "dispositivo", "sitio", "aplicacion", "insert", "reproductor",
        "appareil", "lecteur", "gerat", "seite", "sito", "applicazione", "aplicativo",
    ]

    private static let learnMore = [
        "learn more", "obten mas informacion", "mas informacion", "en savoir plus", "weitere informationen",
        "mehr erfahren", "scopri di piu", "ulteriori informazioni", "saiba mais",
    ]

    private static let terminalReasons: [String: String] = {
        var table: [String: String] = [:]
        func add(_ key: String, _ reasons: [String]) { reasons.forEach { table[$0] = key } }
        add("live-recording-gone", [
            "this live stream recording is not available",
            "la grabacion de esta emision en directo no esta disponible",
            "l'enregistrement de cette diffusion en direct n'est pas disponible",
            "die aufzeichnung dieses livestreams ist nicht verfugbar",
            "la registrazione di questo live streaming non e disponibile",
            "a gravacao desta transmissao ao vivo nao esta disponivel",
        ])
        add("removed-by-uploader", [
            "this video has been removed by the uploader",
            "este video ha sido eliminado por el usuario que lo subio",
            "cette video a ete supprimee par l'utilisateur qui l'a mise en ligne",
            "dieses video wurde vom uploader entfernt",
            "questo video e stato rimosso dall'utente che lo ha caricato",
            "este video foi removido pelo usuario que o enviou",
        ])
        add("account-terminated", [
            "this video is no longer available because the youtube account associated with this video has been terminated",
            "este video ya no esta disponible porque se ha cancelado la cuenta de youtube asociada a este video",
            "cette video n'est plus disponible, car le compte youtube qui lui est associe a ete resilie",
            "dieses video ist nicht mehr verfugbar, weil das mit diesem video verknupfte youtube-konto gekundigt wurde",
            "questo video non e piu disponibile perche l'account youtube associato a questo video e stato chiuso",
            "este video nao esta mais disponivel porque a conta do youtube associada a ele foi encerrada",
        ])
        return table
    }()
}
