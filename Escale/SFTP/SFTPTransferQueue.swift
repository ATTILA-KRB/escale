import Foundation
import Observation
import EscaleCore

/// Un transfert (un fichier) de la file : envoi ou réception.
@MainActor
@Observable
final class SFTPTransfer: Identifiable {
    enum Direction { case upload, download }
    enum State: Equatable { case queued, running, done, failed(String), cancelled }

    let id = UUID()
    let direction: Direction
    let name: String
    let local: URL
    let remote: Data
    let session: SFTPHostSession

    private(set) var state: State = .queued
    private(set) var bytes: UInt64 = 0
    private(set) var total: UInt64?
    /// Débit lissé en octets par seconde (0 hors transfert).
    private(set) var speed: Double = 0
    private(set) var attempts = 0

    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored private var sampleDate = Date()
    @ObservationIgnored private var sampleBytes: UInt64 = 0

    init(direction: Direction, name: String, local: URL, remote: Data, session: SFTPHostSession) {
        self.direction = direction; self.name = name; self.local = local; self.remote = remote; self.session = session
    }

    var fraction: Double? {
        guard let t = total, t > 0 else { return state == .done ? 1 : nil }
        return min(1, Double(bytes) / Double(t))
    }
    var isFinished: Bool {
        switch state { case .done, .failed, .cancelled: true; default: false }
    }

    fileprivate func begin() {
        state = .running; attempts += 1
        bytes = 0; speed = 0; sampleBytes = 0; sampleDate = Date()
    }

    fileprivate func update(_ p: SFTPTransferProgress) {
        guard state == .running else { return }
        bytes = p.bytesTransferred
        if let t = p.totalBytes { total = t }
        let now = Date(), dt = now.timeIntervalSince(sampleDate)
        if dt >= 0.4 {
            let instant = Double(bytes &- sampleBytes) / dt
            speed = speed == 0 ? instant : speed * 0.6 + instant * 0.4
            sampleDate = now; sampleBytes = bytes
        }
    }

    fileprivate func finish(_ s: State) {
        state = s; speed = 0
        if s == .done, let t = total { bytes = t }
    }

    fileprivate func resetForRetry() { state = .queued; bytes = 0; speed = 0 }
}

/// Limite le nombre de rappels de progression transmis à l'interface (un tous les ~80 ms).
private final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func allow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(last) >= 0.08 { last = now; return true }
        return false
    }
}

/// File de transferts commune à tous les hôtes : au plus `maxConcurrent` transferts simultanés,
/// les autres attendent. Annulation et nouvelle tentative par transfert.
@MainActor
@Observable
final class SFTPTransferQueue {
    private(set) var items: [SFTPTransfer] = []
    @ObservationIgnored var maxConcurrent = 3

    var activeCount: Int { items.filter { $0.state == .running || $0.state == .queued }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { true } else { false } }.count }
    var hasFinished: Bool { items.contains { $0.isFinished } }

    func enqueue(_ t: SFTPTransfer) {
        items.append(t)
        pump()
    }

    private func pump() {
        var running = items.filter { $0.state == .running }.count
        for t in items where t.state == .queued && running < maxConcurrent {
            running += 1
            start(t)
        }
    }

    private func start(_ t: SFTPTransfer) {
        t.begin()
        t.task = Task { @MainActor [weak self] in
            await self?.run(t)
        }
    }

    private func run(_ t: SFTPTransfer) async {
        do {
            try await perform(t)
            t.finish(.done)
        } catch {
            var cancelled = Task.isCancelled
            if case SFTPError.cancelled = error { cancelled = true }
            if cancelled { t.finish(.cancelled) } else {
                if SFTPMessages.isChannelLoss(error) { t.session.channelLost() }
                t.finish(.failed(SFTPMessages.describe(error)))
            }
            // Le fichier partiel ne sert à rien : une nouvelle tentative repart de zéro.
            if t.direction == .download { try? FileManager.default.removeItem(at: t.local) }
        }
        t.task = nil
        t.session.transferFinished(t)
        pump()
    }

    private func perform(_ t: SFTPTransfer) async throws {
        guard let client = t.session.client else { throw SFTPError.channelClosed("canal SFTP non ouvert") }
        let gate = ProgressGate()
        let progress: @Sendable (SFTPTransferProgress) -> Void = { [weak t] p in
            guard gate.allow() || p.bytesTransferred == p.totalBytes else { return }
            Task { @MainActor in t?.update(p) }
        }
        switch t.direction {
        case .download:
            try await client.download(remotePath: t.remote, to: t.local, progress: progress)
        case .upload:
            do {
                try await client.upload(localURL: t.local, to: t.remote, progress: progress)
            } catch {
                if case SFTPError.cancelled = error { try? await client.remove(t.remote) }
                throw error
            }
        }
    }

    func cancel(_ t: SFTPTransfer) {
        switch t.state {
        case .queued: t.finish(.cancelled)
        case .running: t.task?.cancel()
        default: break
        }
    }

    func cancelAll() {
        for t in items { cancel(t) }
    }

    func retry(_ t: SFTPTransfer) {
        switch t.state {
        case .failed, .cancelled:
            t.resetForRetry()
            pump()
        default: break
        }
    }

    func clearFinished() { items.removeAll { $0.isFinished } }

    /// Attend la fin de tous les transferts (tests).
    func waitIdle(timeout: Double) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if items.allSatisfy({ $0.isFinished }) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return items.allSatisfy { $0.isFinished }
    }
}
