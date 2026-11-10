import Foundation

/// Champ d'un hôte où une correspondance a été trouvée.
public enum HostSearchField: Hashable, Sendable {
    case name, host, user
    /// Index dans `HostProfile.tags`.
    case tag(Int)
}

/// Correspondance dans un champ : plages (dans la chaîne d'origine de ce champ) à surligner.
public struct HostSearchMatch: Equatable, Sendable {
    public var field: HostSearchField
    public var ranges: [Range<String.Index>]
}

public struct HostSearchResult: Equatable, Sendable {
    public var host: HostProfile
    /// Plus grand = meilleur. 0 pour une requête vide.
    public var score: Int
    public var matches: [HostSearchMatch]
}

/// Recherche floue sur nom, hôte, utilisateur et tags.
///
/// Requête découpée en termes séparés par des espaces ; chaque terme doit correspondre
/// à au moins un champ (ET). Par terme et champ : préfixe > début de mot > sous-chaîne > sous-séquence.
/// Insensible à la casse et aux diacritiques. Les plages sont exprimées dans la chaîne d'origine
/// (la normalisation se fait caractère par caractère, donc les positions restent exactes).
public enum HostSearch {
    /// Requête vide : tout, dans l'ordre d'entrée. Sinon tri par score décroissant, ordre d'entrée à égalité.
    public static func search(_ query: String, in hosts: [HostProfile]) -> [HostSearchResult] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map { fold(Array($0)) }
        if terms.isEmpty { return hosts.map { HostSearchResult(host: $0, score: 0, matches: []) } }

        var scored: [(Int, HostSearchResult)] = []
        for (index, h) in hosts.enumerated() {
            if let r = evaluate(h, terms: terms) { scored.append((index, r)) }
        }
        scored.sort { $0.1.score != $1.1.score ? $0.1.score > $1.1.score : $0.0 < $1.0 }
        return scored.map(\.1)
    }

    // MARK: Interne

    private struct Field {
        var id: HostSearchField
        var text: String
        var chars: [Character]
        var folded: [UInt32]
        var weight: Int // en pourcents
    }

    private static func evaluate(_ h: HostProfile, terms: [[UInt32]]) -> HostSearchResult? {
        var fields: [Field] = []
        func add(_ id: HostSearchField, _ s: String, _ w: Int) {
            guard !s.isEmpty else { return }
            let c = Array(s)
            fields.append(Field(id: id, text: s, chars: c, folded: fold(c), weight: w))
        }
        add(.name, h.name, 100)
        add(.host, h.host, 90)
        if let u = h.user { add(.user, u, 60) }
        for (i, t) in h.tags.enumerated() { add(.tag(i), t, 70) }

        var total = 0
        var perField: [Int: [Range<Int>]] = [:]
        for term in terms {
            var best: (score: Int, field: Int, range: [Range<Int>])?
            for (fi, f) in fields.enumerated() {
                guard let m = match(term, in: f.folded) else { continue }
                // Léger bonus aux champs courts (correspondance plus "complète").
                let s = m.score * f.weight / 100 - min(f.folded.count, 60)
                if best == nil || s > best!.score { best = (s, fi, m.ranges) }
            }
            guard let b = best else { return nil }
            total += b.score
            perField[b.field, default: []].append(contentsOf: b.range)
        }

        let matches = perField.keys.sorted().map { fi -> HostSearchMatch in
            let f = fields[fi]
            let ranges = mergeRanges(perField[fi]!).map { r in
                f.text.index(f.text.startIndex, offsetBy: r.lowerBound)
                    ..< f.text.index(f.text.startIndex, offsetBy: r.upperBound)
            }
            return HostSearchMatch(field: f.id, ranges: ranges)
        }
        return HostSearchResult(host: h, score: total, matches: matches)
    }

    private static let prefixScore = 1000, wordScore = 600, substringScore = 300, subsequenceScore = 100

    /// Meilleur type de correspondance de `term` dans `text` (positions en indices de Character).
    private static func match(_ term: [UInt32], in text: [UInt32]) -> (score: Int, ranges: [Range<Int>])? {
        let n = text.count, m = term.count
        guard m > 0, m <= n else { return nil }
        if Array(text[0..<m]) == term { return (prefixScore, [0..<m]) }
        // Sous-chaîne contiguë : on cherche d'abord un début de mot.
        var firstAny: Int?
        var i = 1
        while i + m <= n {
            if text[i] == term[0], text[i..<(i + m)].elementsEqual(term) {
                if !isAlnum(text[i - 1]) { return (wordScore, [i..<(i + m)]) }
                if firstAny == nil { firstAny = i }
            }
            i += 1
        }
        if let s = firstAny { return (substringScore, [s..<(s + m)]) }
        // Sous-séquence gloutonne.
        var positions: [Int] = []
        var ti = 0
        for (pi, c) in text.enumerated() where ti < m && c == term[ti] { positions.append(pi); ti += 1 }
        guard ti == m else { return nil }
        let span = positions.last! - positions.first! + 1
        let score = max(1, subsequenceScore - (span - m))
        return (score, mergeRanges(positions.map { $0..<($0 + 1) }))
    }

    private static func mergeRanges(_ rs: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for r in rs.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else { out.append(r) }
        }
        return out
    }

    private static func isAlnum(_ v: UInt32) -> Bool {
        guard let s = Unicode.Scalar(v) else { return false }
        return s.properties.isAlphabetic || (v >= 48 && v <= 57)
    }

    /// Un scalaire normalisé (minuscule, sans diacritique) par Character : garde les positions 1-pour-1.
    private static func fold(_ chars: [Character]) -> [UInt32] {
        chars.map { c in
            if let a = c.asciiValue { return (a >= 65 && a <= 90) ? UInt32(a + 32) : UInt32(a) }
            let f = String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return f.unicodeScalars.first?.value ?? c.unicodeScalars.first!.value
        }
    }
}
