import Foundation

/// Jeu de règles de surlignage de la sortie (à la manière de la « coloration syntaxique » de MobaXterm).
public enum HighlightRuleSet: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Aucun surlignage : les octets vont au moteur tels quels.
    case off
    /// Mots-clés d'état : erreurs en rouge, avertissements en jaune, réussites en vert.
    case keywords
    /// Mots-clés, plus adresses IPv4 (magenta) et URL (bleu).
    case keywordsAndNetwork

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Désactivé"
        case .keywords: "Mots-clés"
        case .keywordsAndNetwork: "Mots-clés et réseau"
        }
    }
}

/// Filtre du flux de sortie qui ajoute des couleurs SGR autour des motifs reconnus.
///
/// Règles de sûreté (le flux reste exactement celui du programme, couleurs exceptées) :
/// - seuls des octets SGR sont INSÉRÉS (`ESC[3Xm` avant le motif, `ESC[39m` après) : aucun octet du programme n'est
///   modifié, supprimé ni déplacé ; le texte (copie, accessibilité, journaux lus sur le moteur) est inchangé ;
/// - l'intérieur des séquences d'échappement (CSI, OSC, DCS, APC, PM, SOS, désignations de jeux) n'est jamais touché ;
/// - le texte déjà coloré par le programme (couleur de texte ou de fond, vidéo inverse) est laissé tel quel ;
///   la couleur insérée ne remplace que la couleur de texte par défaut et `ESC[39m` y revient, donc gras et
///   soulignés du programme sont conservés ;
/// - rien n'est surligné sur l'écran alternatif (vim, less, htop, top) ;
/// - un mot coupé entre deux paquets est reconnu : le mot en cours en fin de paquet est retenu (`hasPending`) jusqu'au
///   paquet suivant ou à `flush()` (l'appelant le rend après un court délai, voir `TerminalSession`).
public struct OutputHighlighter: Sendable {
    public let rules: HighlightRuleSet

    /// Longueur maximale d'un mot retenu : au-delà, il passe sans surlignage (sortie binaire, base64…).
    public static let maxTokenLength = 256

    private enum State: Sendable { case ground, escape, escapeIntermediate, csi, string, stringEscape }

    private var state: State = .ground
    private var stringIsOSC = false
    private var csiBuffer: [UInt8] = []
    /// Mot en cours (octets imprimables entre deux séparateurs), retenu pour être examiné entier.
    private var token: [UInt8] = []
    /// Mot trop long : ses octets passent directement jusqu'au prochain séparateur.
    private var tokenOverflow = false

    // État SGR du programme (ce qui interdit le surlignage).
    private var foregroundSet = false
    private var backgroundSet = false
    private var inverse = false
    public private(set) var alternateScreen: Bool

    public init(rules: HighlightRuleSet, alternateScreen: Bool = false) {
        self.rules = rules
        self.alternateScreen = alternateScreen
    }

    /// Vrai si un mot est retenu en attendant la suite du flux.
    public var hasPending: Bool { !token.isEmpty }

    private var canHighlight: Bool { rules != .off && !alternateScreen && !foregroundSet && !backgroundSet && !inverse }

    /// Traite un paquet et rend les octets à donner au moteur (le mot en cours en fin de paquet est retenu).
    public mutating func process(_ data: Data) -> Data {
        if rules == .off { return data }
        var out: [UInt8] = []
        out.reserveCapacity(data.count + 32)
        data.withUnsafeBytes { raw in
            for b in raw.bindMemory(to: UInt8.self) { step(b, &out) }
        }
        return Data(out)
    }

    /// Rend le mot retenu (surligné s'il correspond à une règle).
    public mutating func flush() -> Data {
        var out: [UInt8] = []
        emitToken(&out)
        return Data(out)
    }

    // MARK: Automate

    private mutating func step(_ b: UInt8, _ out: inout [UInt8]) {
        switch state {
        case .ground:
            if b == 0x1b {
                emitToken(&out)
                state = .escape
                out.append(b)
            } else if b < 0x20 || b == 0x7f || b == 0x20 {
                emitToken(&out)
                tokenOverflow = false
                out.append(b)
            } else if tokenOverflow || !canHighlight {
                emitToken(&out)
                out.append(b)
            } else {
                token.append(b)
                if token.count > Self.maxTokenLength {
                    out.append(contentsOf: token); token.removeAll(keepingCapacity: true)
                    tokenOverflow = true
                }
            }
        case .escape:
            out.append(b)
            switch b {
            case UInt8(ascii: "["): state = .csi; csiBuffer.removeAll(keepingCapacity: true)
            case UInt8(ascii: "]"): state = .string; stringIsOSC = true
            case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"): state = .string; stringIsOSC = false
            case 0x1b: state = .escape
            case 0x20...0x2f: state = .escapeIntermediate
            case 0x18, 0x1a: state = .ground
            default: state = .ground
            }
        case .escapeIntermediate:
            out.append(b)
            if b == 0x1b { state = .escape } else if (0x30...0x7e).contains(b) || b == 0x18 || b == 0x1a { state = .ground }
        case .csi:
            out.append(b)
            if b == 0x1b { state = .escape; return }
            if b == 0x18 || b == 0x1a { state = .ground; return }
            if (0x40...0x7e).contains(b) {
                interpretCSI(final: b)
                state = .ground
            } else if csiBuffer.count < 128 {
                csiBuffer.append(b)
            }
        case .string:
            out.append(b)
            if b == 0x1b { state = .stringEscape } else if b == 0x07 && stringIsOSC { state = .ground } else if b == 0x18 || b == 0x1a { state = .ground }
        case .stringEscape:
            // ESC \ (ST) termine la chaîne ; tout autre octet : l'ESC a ouvert une nouvelle séquence.
            if b == UInt8(ascii: "\\") { out.append(b); state = .ground } else { state = .escape; step(b, &out) }
        }
    }

    private mutating func interpretCSI(final: UInt8) {
        let params = csiBuffer
        if final == UInt8(ascii: "m") {
            // SGR sans préfixe privé ni intermédiaire.
            guard params.allSatisfy({ (0x30...0x3b).contains($0) }) else { return }
            applySGR(params)
        } else if final == UInt8(ascii: "h") || final == UInt8(ascii: "l") {
            guard params.first == UInt8(ascii: "?") else { return }
            let on = final == UInt8(ascii: "h")
            for p in String(decoding: params.dropFirst(), as: UTF8.self).split(separator: ";") {
                if p == "47" || p == "1047" || p == "1049" { alternateScreen = on }
            }
        }
    }

    private mutating func applySGR(_ params: [UInt8]) {
        let groups = String(decoding: params, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        if groups.isEmpty { resetSGR(); return }
        var i = 0
        while i < groups.count {
            let g = groups[i]
            // Forme à deux-points (38:2::r:g:b) : un seul groupe, premier composant significatif.
            let head = g.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let code = head.isEmpty ? 0 : (Int(head) ?? -1)
            switch code {
            case 0: resetSGR()
            case 7: inverse = true
            case 27: inverse = false
            case 30...37, 90...97: foregroundSet = true
            case 39: foregroundSet = false
            case 40...47, 100...107: backgroundSet = true
            case 49: backgroundSet = false
            case 38, 48:
                if code == 38 { foregroundSet = true } else { backgroundSet = true }
                // Forme à points-virgules : sauter les sous-paramètres (5;n ou 2;r;g;b).
                if !g.contains(":"), i + 1 < groups.count {
                    let kind = Int(groups[i + 1]) ?? -1
                    i += kind == 5 ? 2 : (kind == 2 ? 4 : 1)
                }
            default: break
            }
            i += 1
        }
    }

    private mutating func resetSGR() { foregroundSet = false; backgroundSet = false; inverse = false }

    // MARK: Correspondances

    private mutating func emitToken(_ out: inout [UInt8]) {
        guard !token.isEmpty else { return }
        let matches = Self.matches(in: token, rules: rules)
        if matches.isEmpty {
            out.append(contentsOf: token)
        } else {
            var pos = 0
            for m in matches {
                out.append(contentsOf: token[pos..<m.range.lowerBound])
                out.append(contentsOf: [0x1b, UInt8(ascii: "["), UInt8(ascii: "3"), UInt8(ascii: "0") + m.color.rawValue, UInt8(ascii: "m")])
                out.append(contentsOf: token[m.range])
                out.append(contentsOf: [0x1b, UInt8(ascii: "["), UInt8(ascii: "3"), UInt8(ascii: "9"), UInt8(ascii: "m")])
                pos = m.range.upperBound
            }
            out.append(contentsOf: token[pos...])
        }
        token.removeAll(keepingCapacity: true)
    }

    /// Couleur ANSI insérée (code 30 + valeur) : couleurs NORMALES de la palette, lisibles sur tous les thèmes.
    public enum Color: UInt8, Sendable {
        case red = 1, green = 2, yellow = 3, blue = 4, magenta = 5
    }

    public struct Match: Equatable, Sendable {
        public let range: Range<Int>
        public let color: Color
    }

    static let keywordColors: [[UInt8]: Color] = {
        var d: [[UInt8]: Color] = [:]
        let red = ["error", "errors", "err", "fail", "failed", "fails", "failure", "fatal", "critical", "crit", "denied",
                   "refused", "panic", "exception", "abort", "aborted", "emerg", "alert", "unreachable",
                   "erreur", "erreurs", "échec", "échecs", "échoué", "échouée", "refusé", "refusée", "interdit"]
        let yellow = ["warning", "warnings", "warn", "deprecated", "caution", "avertissement", "attention"]
        let green = ["ok", "success", "successful", "successfully", "succeeded", "passed", "done",
                     "réussi", "réussie", "succès"]
        for w in red { d[Array(w.utf8)] = .red }
        for w in yellow { d[Array(w.utf8)] = .yellow }
        for w in green { d[Array(w.utf8)] = .green }
        return d
    }()
    static let maxKeywordLength = keywordColors.keys.map(\.count).max() ?? 0

    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || b == 0x5f || b >= 0x80
    }
    private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    /// Correspondances d'un mot, triées et disjointes. Exposé pour les tests.
    public static func matches(in token: [UInt8], rules: HighlightRuleSet) -> [Match] {
        guard rules != .off else { return [] }
        var found: [Match] = []
        if rules == .keywordsAndNetwork {
            found += urls(in: token)
            for ip in ipv4(in: token) where !found.contains(where: { $0.range.overlaps(ip.range) }) { found.append(ip) }
        }
        for kw in keywords(in: token) where !found.contains(where: { $0.range.overlaps(kw.range) }) { found.append(kw) }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func keywords(in t: [UInt8]) -> [Match] {
        var out: [Match] = []
        var i = 0
        while i < t.count {
            guard isWordByte(t[i]) else { i += 1; continue }
            var j = i
            var ascii = true
            while j < t.count, isWordByte(t[j]) { if t[j] >= 0x80 { ascii = false }; j += 1 }
            let len = j - i
            if len <= maxKeywordLength * 2 {
                let word: [UInt8] = ascii
                    ? t[i..<j].map { ($0 >= 0x41 && $0 <= 0x5a) ? $0 + 0x20 : $0 }
                    : Array(String(decoding: t[i..<j], as: UTF8.self).lowercased().utf8)
                if let c = keywordColors[word] { out.append(Match(range: i..<j, color: c)) }
            }
            i = j
        }
        return out
    }

    private static let schemes: [[UInt8]] = ["https://", "http://", "ftp://", "sftp://", "ssh://"].map { Array($0.utf8) }

    private static func urls(in t: [UInt8]) -> [Match] {
        var out: [Match] = []
        var i = 0
        while i < t.count {
            guard let s = schemes.first(where: { t.count - i > $0.count && t[i..<(i + $0.count)].elementsEqual($0) }),
                  i == 0 || !isWordByte(t[i - 1]) else { i += 1; continue }
            var end = t.count
            // Ponctuation finale (fin de phrase, guillemets, parenthèse fermante) hors URL.
            while end > i + s.count, [UInt8](".,;:!?'\")]>}".utf8).contains(t[end - 1]) { end -= 1 }
            if end > i + s.count { out.append(Match(range: i..<end, color: .blue)) }
            i = t.count
        }
        return out
    }

    /// IPv4 `a.b.c.d` (chaque octet ≤ 255), suivie éventuellement de `/préfixe` ou `:port`.
    private static func ipv4(in t: [UInt8]) -> [Match] {
        var out: [Match] = []
        var i = 0
        while i < t.count {
            guard isDigit(t[i]), i == 0 || !(isWordByte(t[i - 1]) || t[i - 1] == UInt8(ascii: ".")) else { i += 1; continue }
            var j = i
            var parts = 0
            var ok = true
            while parts < 4 {
                var k = j, value = 0
                while k < t.count, isDigit(t[k]), k - j < 3 { value = value * 10 + Int(t[k] - 0x30); k += 1 }
                if k == j || value > 255 || (k < t.count && isDigit(t[k])) { ok = false; break }
                parts += 1
                j = k
                if parts < 4 {
                    guard j < t.count, t[j] == UInt8(ascii: ".") else { ok = false; break }
                    j += 1
                }
            }
            if ok, j < t.count, isWordByte(t[j]) || (t[j] == UInt8(ascii: ".") && j + 1 < t.count && isDigit(t[j + 1])) { ok = false }
            if ok {
                // Suffixe /préfixe ou :port.
                if j + 1 < t.count, t[j] == UInt8(ascii: "/") || t[j] == UInt8(ascii: ":"), isDigit(t[j + 1]) {
                    var k = j + 1
                    while k < t.count, isDigit(t[k]), k - j <= 5 { k += 1 }
                    if k == t.count || !isWordByte(t[k]) { j = k }
                }
                out.append(Match(range: i..<j, color: .magenta))
                i = j
            } else {
                while i < t.count, isDigit(t[i]) || t[i] == UInt8(ascii: ".") { i += 1 }
            }
        }
        return out
    }
}
