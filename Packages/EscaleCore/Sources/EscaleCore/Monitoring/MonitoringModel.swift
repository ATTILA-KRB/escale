import Foundation

/// Un relevé brut tel qu'émis par `MonitoringScript` (compteurs cumulés, pas encore de débit ni de CPU).
public struct MonitoringRawSample: Equatable, Sendable {
    public var os = ""
    public var load1: Double?
    /// Linux : compteurs cumulés de /proc/stat (total, inactif + attente d'E/S).
    public var cpuTotal: UInt64?
    public var cpuIdle: UInt64?
    /// macOS : pourcentage direct (somme des %cpu de ps ÷ nombre de cœurs).
    public var cpuPercentDirect: Double?
    public var memTotal: UInt64?
    public var memUsed: UInt64?
    public var diskTotal: UInt64?
    public var diskUsed: UInt64?
    public var diskPercent: Int?
    /// Octets cumulés entrée / sortie, interfaces physiques seulement (voir `MonitoringStreamParser.isCountedInterface`).
    public var netIn: UInt64?
    public var netOut: UInt64?
    public var users: Int?
    public var uptime: Double?
    /// Horloge du relevé en secondes : l'uptime distant quand il a une partie fractionnaire fiable (Linux),
    /// sinon renseignée par l'appelant (heure de réception).
    public var received: TimeInterval = 0

    public init() {}
}

/// Événement issu du flux du script.
public enum MonitoringEvent: Equatable, Sendable {
    case sample(MonitoringRawSample)
    /// Le système distant n'est ni Linux ni macOS : la barre affiche « monitoring indisponible ».
    case unsupported(String)
}

/// Analyse incrémentale de la sortie du script : accepte des morceaux arbitraires (coupés au milieu d'une ligne),
/// ignore tout ce qui n'est pas entre `@@ESC begin` et `@@ESC end` (bannière, bruit) et tout champ illisible.
public struct MonitoringStreamParser: Sendable {
    private var pending = Data()
    private var current: MonitoringRawSample?
    private var netIn: UInt64 = 0, netOut: UInt64 = 0, sawNet = false
    /// Plafond d'une ligne en cours (une ligne plus longue est abandonnée : flux corrompu).
    static let maxLine = 4096

    public init() {}

    /// Interfaces écartées du débit : bouclage, ponts et réseaux virtuels (double compte avec l'interface physique).
    public static func isCountedInterface(_ name: String) -> Bool {
        let n = name.lowercased()
        let skipped = ["lo", "veth", "docker", "br-", "virbr", "vnet", "cni", "flannel", "cali", "tun", "tap",
                       "awdl", "llw", "utun", "gif", "stf", "anpi", "ap", "bridge", "nan", "p2p", "sit", "ip6tnl"]
        return !skipped.contains { p in p.count <= 2 ? (n == p || (n.hasPrefix(p) && n.dropFirst(p.count).allSatisfy(\.isNumber))) : n.hasPrefix(p) }
    }

    public mutating func feed(_ data: Data, now: TimeInterval) -> [MonitoringEvent] {
        pending.append(data)
        var events: [MonitoringEvent] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            if let e = handle(line.trimmingCharacters(in: .whitespacesAndNewlines), now: now) { events.append(e) }
        }
        if pending.count > Self.maxLine { pending.removeAll() }
        return events
    }

    private mutating func handle(_ line: String, now: TimeInterval) -> MonitoringEvent? {
        if line == "@@ESC begin" {
            current = MonitoringRawSample(); netIn = 0; netOut = 0; sawNet = false
            return nil
        }
        if line.hasPrefix("@@ESC unsupported") {
            return .unsupported(line.dropFirst("@@ESC unsupported".count).trimmingCharacters(in: .whitespaces))
        }
        if line == "@@ESC end" {
            guard var s = current else { return nil }
            current = nil
            if sawNet { s.netIn = netIn; s.netOut = netOut }
            if s.received == 0 { s.received = now }
            return .sample(s)
        }
        guard current != nil, let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[line.startIndex..<eq]
        let f = line[line.index(after: eq)...].split(separator: " ").map(String.init)
        switch key {
        case "os": current?.os = f.first ?? ""
        case "load": current?.load1 = f.first.flatMap(Double.init)
        case "cpu":
            if f.count == 2, let t = UInt64(f[0]), let i = UInt64(f[1]) { current?.cpuTotal = t; current?.cpuIdle = i }
        case "cpupct": current?.cpuPercentDirect = f.first.flatMap(Double.init)
        case "mem":
            if f.count == 2, let t = UInt64(f[0]), let u = UInt64(f[1]) { current?.memTotal = t; current?.memUsed = min(u, t) }
        case "disk":
            if f.count == 3, let t = UInt64(f[0]), let u = UInt64(f[1]) {
                current?.diskTotal = t; current?.diskUsed = u
                current?.diskPercent = Int(f[2].trimmingCharacters(in: CharacterSet(charactersIn: "%")))
            }
        case "net":
            if f.count == 3, let rx = UInt64(f[1]), let tx = UInt64(f[2]), Self.isCountedInterface(f[0]) {
                netIn &+= rx; netOut &+= tx; sawNet = true
            }
        case "users": current?.users = f.first.flatMap(Int.init)
        case "uptime":
            if let u = f.first.flatMap(Double.init) {
                current?.uptime = u
                // Un uptime fractionnaire (/proc/uptime) sert d'horloge : insensible à la gigue du réseau.
                if f[0].contains(".") { current?.received = u }
            }
        default: break
        }
        return nil
    }
}

/// Valeurs affichées par la barre.
public struct MonitoringSnapshot: Equatable, Sendable {
    public var load1: Double?
    /// 0…100 ; nil jusqu'au second relevé (Linux : delta de compteurs).
    public var cpuPercent: Double?
    public var memUsed: UInt64?
    public var memTotal: UInt64?
    public var diskPercent: Int?
    public var diskUsed: UInt64?
    public var diskTotal: UInt64?
    /// Octets par seconde ; nil jusqu'au second relevé.
    public var netInRate: Double?
    public var netOutRate: Double?
    public var users: Int?
    public var uptime: TimeInterval?
    public var os = ""

    public init() {}

    public var memPercent: Double? {
        guard let u = memUsed, let t = memTotal, t > 0 else { return nil }
        return Double(u) / Double(t) * 100
    }
}

/// Calcule les deltas (CPU, débits) entre deux relevés consécutifs.
public struct MonitoringCalculator: Sendable {
    private var previous: MonitoringRawSample?

    public init() {}

    public mutating func reset() { previous = nil }

    public mutating func ingest(_ s: MonitoringRawSample) -> MonitoringSnapshot {
        var out = MonitoringSnapshot()
        out.os = s.os
        out.load1 = s.load1
        out.memUsed = s.memUsed; out.memTotal = s.memTotal
        out.diskPercent = s.diskPercent; out.diskUsed = s.diskUsed; out.diskTotal = s.diskTotal
        out.users = s.users; out.uptime = s.uptime
        out.cpuPercent = s.cpuPercentDirect.map { min(max($0, 0), 100) }
        if let p = previous {
            if let t = s.cpuTotal, let i = s.cpuIdle, let pt = p.cpuTotal, let pi = p.cpuIdle, t > pt, i >= pi {
                let dt = Double(t - pt), di = Double(i - pi)
                out.cpuPercent = min(max((1 - di / dt) * 100, 0), 100)
            }
            let dt = s.received - p.received
            // Compteur qui recule (redémarrage d'interface, débordement) : pas de débit pour ce relevé.
            if dt > 0.1 {
                if let a = s.netIn, let b = p.netIn, a >= b { out.netInRate = Double(a - b) / dt }
                if let a = s.netOut, let b = p.netOut, a >= b { out.netOutRate = Double(a - b) / dt }
            }
        }
        previous = s
        return out
    }
}

/// Mise en forme française, compacte.
public enum MonitoringFormat {
    private static func number(_ v: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", v).replacingOccurrences(of: ".", with: ",")
    }

    /// 1 536 → « 1,5 Ko » (unités binaires, notations françaises).
    public static func bytes(_ v: UInt64) -> String { bytes(Double(v)) }
    public static func bytes(_ v: Double) -> String {
        let units = ["o", "Ko", "Mo", "Go", "To", "Po"]
        var x = max(v, 0), i = 0
        while x >= 1024, i < units.count - 1 { x /= 1024; i += 1 }
        if i == 0 { return "\(Int(x)) o" }
        return number(x, decimals: x < 10 ? 1 : 0) + " " + units[i]
    }

    public static func rate(_ v: Double?) -> String { v.map { bytes($0) + "/s" } ?? "—" }

    public static func percent(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) %" } ?? "—" }

    public static func load(_ v: Double?) -> String { v.map { number($0, decimals: 2) } ?? "—" }

    /// 93 784 s → « 1 j 2 h » ; 4 500 s → « 1 h 15 min » ; 90 s → « 1 min ».
    public static func uptime(_ s: TimeInterval?) -> String {
        guard let s, s >= 0 else { return "—" }
        let total = Int(s)
        let d = total / 86400, h = total % 86400 / 3600, m = total % 3600 / 60
        if d > 0 { return "\(d) j \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return "\(max(m, 0)) min"
    }
}
