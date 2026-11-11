import SwiftUI
import AppKit
import Observation
import EscaleCore

/// M3 : diffusion de la saisie vers plusieurs panneaux, commande lancée sur plusieurs hôtes.
/// - Diffusion : un observateur de saisie (clé « multiexec ») sur chaque panneau du groupe rejoue les octets
///   bruts vers les autres via `TerminalSession.write(_:)` (qui ne re-notifie pas : aucune boucle).
/// - Exécution groupée : `ssh -T <hôte> <commande>` sur le maître de chaque hôte (`OpenSSHTransport.exec`).
@MainActor
@Observable
final class MultiExecFeature: AppFeature {
    static let observerKey = "multiexec"
    static let execSheetID = "multiexec-exec"
    static let broadcastSheetID = "multiexec-broadcast"

    @ObservationIgnored private(set) weak var model: AppModel?
    func attach(_ model: AppModel) { self.model = model }

    func shutdown() async {
        stopBroadcast()
        execTask?.cancel()
    }

    // MARK: - Diffusion de la saisie

    /// Ensemble des panneaux qui diffusent et reçoivent.
    enum BroadcastScope: Equatable {
        /// Tous les panneaux d'un onglet (les panneaux créés ensuite rejoignent le groupe).
        case tab(UUID)
        /// Tous les panneaux de tous les onglets.
        case allTabs
        /// Panneaux choisis un par un.
        case panes(Set<UUID>)
    }

    private(set) var broadcastScope: BroadcastScope?
    var isBroadcasting: Bool { broadcastScope != nil }
    /// Panneaux du groupe actuel (pour le bandeau et les tests).
    private(set) var broadcastPaneIDs: Set<UUID> = []
    /// Nombre d'écritures répliquées depuis le début de la diffusion (une par panneau destinataire).
    @ObservationIgnored private(set) var replicatedWrites = 0
    /// Dernier réglage choisi, rappelé par ⌥⌘I.
    var lastScope: BroadcastScope?
    /// Panneaux cochés dans la feuille de choix.
    var sheetSelection: Set<UUID> = []
    var broadcastSheetOpen = false
    @ObservationIgnored private var syncTimer: Timer?
    @ObservationIgnored private var decorated: Set<UUID> = []

    private var allPanes: [Pane] { model?.workspace.tabs.flatMap(\.panes) ?? [] }

    /// Panneaux concernés par `scope`, dans l'ordre des onglets.
    func members(of scope: BroadcastScope) -> [Pane] {
        guard let model else { return [] }
        switch scope {
        case .tab(let id): return model.workspace.tabs.first { $0.id == id }?.panes ?? []
        case .allTabs: return allPanes
        case .panes(let ids): return allPanes.filter { ids.contains($0.id) }
        }
    }

    /// Démarre la diffusion. Retourne faux s'il y a moins de deux panneaux dans le groupe (rien à diffuser).
    @discardableResult
    func startBroadcast(_ scope: BroadcastScope) -> Bool {
        guard members(of: scope).count >= 2 else { return false }
        stopBroadcast()
        broadcastScope = scope
        lastScope = scope
        replicatedWrites = 0
        sync()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        return true
    }

    func stopBroadcast() {
        syncTimer?.invalidate(); syncTimer = nil
        broadcastScope = nil
        broadcastPaneIDs = []
        for p in allPanes { p.session.inputObservers[Self.observerKey] = nil }
        for p in allPanes { decorate(p, on: false) }
        decorated = []
    }

    /// ⌥⌘I : arrête, ou démarre avec le dernier réglage (sinon l'onglet actif). Ouvre la feuille de choix si
    /// le groupe n'a pas au moins deux panneaux.
    func toggleBroadcast() {
        if isBroadcasting { stopBroadcast(); return }
        var scope = lastScope
        if case .tab(let id)? = scope, model?.workspace.tabs.contains(where: { $0.id == id }) != true { scope = nil }
        if scope == nil, let t = model?.workspace.activeTab { scope = .tab(t.id) }
        if let scope, startBroadcast(scope) { return }
        if let t = model?.workspace.activeTab, t.panes.count < 2, startBroadcast(.allTabs) { return }
        openBroadcastSheet()
    }

    func openBroadcastSheet() {
        guard model?.activeFeatureSheet == nil else { return }
        if case .panes(let ids)? = lastScope { sheetSelection = ids } else if let t = model?.workspace.activeTab {
            sheetSelection = Set(t.panes.map(\.id))
        }
        broadcastSheetOpen = true
        model?.activeFeatureSheet = Self.broadcastSheetID
    }

    func closeBroadcastSheet() {
        broadcastSheetOpen = false
        if model?.activeFeatureSheet == Self.broadcastSheetID { model?.activeFeatureSheet = nil }
    }

    /// Resynchronise observateurs et bordures avec le groupe actuel (panneaux créés ou fermés depuis).
    private func sync() {
        guard let scope = broadcastScope else { return }
        if case .tab(let id) = scope, model?.workspace.tabs.contains(where: { $0.id == id }) != true { stopBroadcast(); return }
        let members = members(of: scope).filter { !$0.isClosing }
        let ids = Set(members.map(\.id))
        for p in allPanes where !ids.contains(p.id) {
            if p.session.inputObservers[Self.observerKey] != nil { p.session.inputObservers[Self.observerKey] = nil }
            if decorated.contains(p.id) { decorate(p, on: false) }
        }
        for p in members {
            if p.session.inputObservers[Self.observerKey] == nil {
                p.session.inputObservers[Self.observerKey] = { [weak self, weak p] data in
                    guard let self, let p else { return }
                    self.replicate(data, from: p)
                }
            }
            if !decorated.contains(p.id) { decorate(p, on: true) }
        }
        decorated = ids
        if broadcastPaneIDs != ids { broadcastPaneIDs = ids }
        if members.count < 2 { stopBroadcast() }   // plus personne à qui diffuser
    }

    /// Rejoue la saisie de `source` vers les autres panneaux du groupe (octets bruts : touches spéciales,
    /// collage entier en un seul envoi). Les réponses automatiques du terminal ne sont pas diffusées.
    private func replicate(_ data: Data, from source: Pane) {
        guard let scope = broadcastScope, !BroadcastFilter.isTerminalReport(data) else { return }
        let group = members(of: scope)
        guard group.contains(where: { $0.id == source.id }) else { return }
        for p in group where p.id != source.id && !p.isClosing && p.status == .running {
            p.session.write(data)
            replicatedWrites += 1
        }
    }

    /// Bordure rouge sur la vue du moteur (aucun type du moteur : `view` est une `NSView`).
    private func decorate(_ pane: Pane, on: Bool) {
        let v = pane.session.engine.view
        v.wantsLayer = true
        v.layer?.borderWidth = on ? 2 : 0
        v.layer?.borderColor = on ? NSColor.systemRed.cgColor : nil
    }

    /// Bordure actuellement posée (tests).
    func hasBroadcastBorder(_ pane: Pane) -> Bool {
        let l = pane.session.engine.view.layer
        return (l?.borderWidth ?? 0) > 0 && l?.borderColor != nil
    }

    // MARK: - Exécution groupée

    /// Brouillon de la feuille « Exécuter une commande… ».
    struct ExecDraft: Identifiable {
        let id = UUID()
        var hosts: [HostProfile]
        var command = ""
        var timeout: Double = 30
    }

    @MainActor @Observable
    final class ExecRow: Identifiable {
        enum Phase: Equatable { case waiting, connecting, running, done }
        let host: HostProfile
        nonisolated let id: UUID
        var phase: Phase = .waiting
        var result: RemoteExecResult?
        init(host: HostProfile) { self.host = host; self.id = host.id }
    }

    @MainActor @Observable
    final class ExecRun: Identifiable {
        nonisolated let id = UUID()
        let command: String
        let timeout: Double
        var rows: [ExecRow]
        var isRunning = true
        var startedAt = Date()
        init(command: String, timeout: Double, hosts: [HostProfile]) {
            self.command = command; self.timeout = timeout; self.rows = hosts.map(ExecRow.init)
        }
        var finishedCount: Int { rows.filter { $0.phase == .done }.count }
        var failedCount: Int { rows.filter { $0.result?.isSuccess == false }.count }
    }

    var execDraft: ExecDraft?
    private(set) var execRun: ExecRun?
    @ObservationIgnored private var execTask: Task<Void, Never>?
    /// Sortie maximale gardée par flux et par hôte.
    static let maxOutputBytes = 64 * 1024

    /// Ouvre la feuille pour les hôtes donnés.
    func beginGroupExec(hosts: [HostProfile]) {
        guard !hosts.isEmpty, model?.activeFeatureSheet == nil else { return }
        execDraft = ExecDraft(hosts: hosts)
        model?.activeFeatureSheet = Self.execSheetID
    }

    func cancelGroupExecDraft() {
        execDraft = nil
        if model?.activeFeatureSheet == Self.execSheetID { model?.activeFeatureSheet = nil }
    }

    /// Valide la feuille et lance l'exécution. Les résultats s'affichent dans un panneau (pas une feuille :
    /// une demande d'authentification d'un hôte non connecté doit pouvoir s'afficher pendant l'exécution).
    @discardableResult
    func startGroupExec(command: String, timeout: Double, hosts: [HostProfile]) -> ExecRun? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !hosts.isEmpty, execRun?.isRunning != true else { return nil }
        cancelGroupExecDraft()
        let run = ExecRun(command: cmd, timeout: timeout, hosts: hosts)
        execRun = run
        execTask = Task { await self.perform(run) }
        return run
    }

    /// « Relancer » : même commande, mêmes hôtes.
    func rerun() {
        guard let r = execRun, !r.isRunning else { return }
        startGroupExec(command: r.command, timeout: r.timeout, hosts: r.rows.map(\.host))
    }

    func closeResults() { if execRun?.isRunning != true { execRun = nil } }

    /// Attend la fin de l'exécution en cours (tests).
    func waitForRun() async { await execTask?.value }

    private func perform(_ run: ExecRun) async {
        let limits = GroupExecLimits(timeout: run.timeout, maxOutputBytes: Self.maxOutputBytes, maxConcurrent: 16)
        let targets = run.rows.map { row in
            GroupExecTarget(id: row.id, name: row.host.name) { [weak self] cmd, limits in
                guard let self else { return RemoteExecResult(failure: "annulé") }
                return await self.execute(on: row, command: cmd, limits: limits)
            }
        }
        await GroupExec.run(command: run.command, targets: targets, limits: limits) { _, _ in }
        run.isRunning = false
    }

    /// Un hôte : lien maître (connecté d'abord si besoin, partagé avec les onglets ouverts), puis commande.
    /// Le lien est rattaché pour la durée de la commande : déconnexion différée ensuite si aucun onglet ne l'utilise.
    private func execute(on row: ExecRow, command: String, limits: GroupExecLimits) async -> RemoteExecResult {
        guard let model else { return RemoteExecResult(failure: "application arrêtée") }
        let link = model.connections.connection(for: row.host).acquireLink()
        defer { link.release() }
        var result = RemoteExecResult(failure: "non exécuté")
        for attempt in 0..<2 {
            row.phase = .connecting
            do { try await link.ensureConnected() } catch {
                result = RemoteExecResult(failure: link.message(for: error)); break
            }
            row.phase = .running
            do {
                result = try await link.transport.exec(command, timeout: limits.timeout, maxOutputBytes: limits.maxOutputBytes)
                break
            } catch SSHTransportError.notConnected where attempt == 0 {
                // Maître mort sans que personne s'en soit aperçu : même chemin qu'une coupure, puis un second essai.
                link.handleConnectionLost()
                _ = await link.waitReconnect()
            } catch SSHTransportError.sessionRefused(let m) {
                result = RemoteExecResult(failure: "session refusée : \(m)"); break
            } catch {
                result = RemoteExecResult(failure: SSHLink.describe(error)); break
            }
        }
        row.phase = .done
        row.result = result
        return result
    }

    /// Texte copiable de tous les résultats.
    func reportText(_ run: ExecRun) -> String {
        GroupExecReport.text(command: run.command, entries: run.rows.compactMap { r in r.result.map { (r.host.name, $0) } })
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
