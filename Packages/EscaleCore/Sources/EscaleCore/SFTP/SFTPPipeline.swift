import Foundation

/// Fenêtre adaptative de requêtes en vol : recherche du genou du débit par essais successifs.
///
/// Principe (le produit bande passante x latence est inconnu, la mesure directe de la latence est faussée par la
/// consommation des réponses dans l'ordre) : on mesure le débit par intervalles de 250 ms. Tant qu'agrandir la
/// fenêtre améliore le débit de plus de 10 %, on continue (x1,5) ; un gain nul signale la saturation du lien : retour au
/// palier précédent puis maintien pendant 8 intervalles avant de resonder. Une baisse de plus de 10 % inverse le sens.
/// Valeur pure, sans horloge : le temps est passé en paramètre (testable par simulation).
struct SFTPWindowController: Sendable {
    private(set) var window: Int
    let minWindow: Int
    let maxWindow: Int
    let adaptive: Bool

    static let interval = 0.25
    static let gain = 1.10
    static let settleIntervals = 8

    private var intervalStart: Double?
    private var intervalBytes: UInt64 = 0
    private var lastThroughput = 0.0
    private var direction = 1
    private var settled = 0
    private var previousWindow: Int

    init(initial: Int, min lo: Int, max hi: Int, adaptive: Bool) {
        let low = Swift.max(1, lo), high = Swift.max(Swift.max(1, lo), hi)
        minWindow = low; maxWindow = high; self.adaptive = adaptive
        window = adaptive ? Swift.min(high, Swift.max(low, initial)) : Swift.max(1, initial)
        previousWindow = window
    }

    /// Enregistre `bytes` octets terminés à l'instant `now` (secondes, base quelconque mais croissante).
    mutating func record(bytes: Int, at now: Double) {
        guard adaptive else { return }
        guard let start = intervalStart else { intervalStart = now; intervalBytes = UInt64(bytes); return }
        intervalBytes += UInt64(bytes)
        let dt = now - start
        guard dt >= Self.interval else { return }
        let throughput = Double(intervalBytes) / dt
        intervalStart = now; intervalBytes = 0
        step(throughput)
    }

    private mutating func step(_ tp: Double) {
        defer { lastThroughput = tp }
        guard lastThroughput > 0 else { move(+1); return }          // premier intervalle : référence, puis on sonde
        if settled > 0 {
            settled -= 1
            if settled == 0 { move(+1) }
            return
        }
        if tp > lastThroughput * Self.gain {
            move(direction)
        } else if tp < lastThroughput / Self.gain {
            move(-direction)
        } else {
            // Plateau : le lien est saturé. En montée on revient au palier d'avant (inutile d'en garder davantage).
            if direction > 0 { window = previousWindow }
            settled = Self.settleIntervals
        }
    }

    private mutating func move(_ dir: Int) {
        direction = dir
        previousWindow = window
        if dir > 0 { window = Swift.min(maxWindow, window + Swift.max(1, window / 2)) }
        else { window = Swift.max(minWindow, window * 2 / 3) }
        if window == previousWindow { settled = Self.settleIntervals }   // borne atteinte : inutile d'insister
    }
}

/// Mesure d'un transfert : débit lissé (fenêtre glissante de 3 s), fenêtre adaptative, cadence des instantanés.
struct SFTPTransferMeter: Sendable {
    private(set) var windowController: SFTPWindowController
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var samples: [(t: Double, done: UInt64)] = []
    private var firstSample = 0
    private var lastSampleT = -1.0
    private var lastEmit = -1.0

    static let rateSpan = 3.0
    static let emitInterval = 0.1

    init(configuration: SFTPClientConfiguration) {
        windowController = SFTPWindowController(initial: configuration.window, min: configuration.minWindow,
                                                max: Swift.max(configuration.maxWindow, configuration.window),
                                                adaptive: configuration.adaptiveWindow)
        start = clock.now
    }

    var window: Int { windowController.window }
    private var now: Double { let d = clock.now - start; return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    var elapsed: Duration { clock.now - start }

    /// À appeler à chaque bloc terminé ; `done` = octets en place après ce bloc (offset de reprise inclus).
    mutating func advance(bytes: Int, done: UInt64) {
        let t = now
        windowController.record(bytes: bytes, at: t)
        if t - lastSampleT >= 0.05 {
            samples.append((t, done)); lastSampleT = t
            while firstSample < samples.count - 1, t - samples[firstSample].t > Self.rateSpan { firstSample += 1 }
            if firstSample > 1024 { samples.removeFirst(firstSample); firstSample = 0 }
        }
    }

    var bytesPerSecond: Double {
        guard firstSample < samples.count - 1, let a = samples.indices.contains(firstSample) ? samples[firstSample] : nil,
              let b = samples.last, b.t - a.t >= 0.2 else { return 0 }
        return Double(b.done - a.done) / (b.t - a.t)
    }

    func snapshot(done: UInt64, total: UInt64?) -> SFTPTransferSnapshot {
        SFTPTransferSnapshot(bytesTransferred: done, totalBytes: total, bytesPerSecond: bytesPerSecond,
                             window: window, elapsed: elapsed)
    }

    /// Instantané si la cadence (10/s) le permet, ou si `force`.
    mutating func snapshotIfDue(done: UInt64, total: UInt64?, force: Bool = false) -> SFTPTransferSnapshot? {
        let t = now
        guard force || t - lastEmit >= Self.emitInterval else { return nil }
        lastEmit = t
        return snapshot(done: done, total: total)
    }
}
