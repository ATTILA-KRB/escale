import AppKit
import CryptoKit
import Foundation
import EscaleCore

/// Scénario `--selftest-auth <dossier>` : bibliothèque, recherche, import, askpass et dialogues, contre un sshd local.
/// Piloté uniquement par l'API interne (les demandes de dialogue sont résolues par `AuthDialogCenter.resolve`, pas par des
/// clics) : aucun événement clavier/souris global, pas d'activation de l'app. Écrit result.json + PNG dans le dossier.
///
/// Variables d'environnement (posées par scripts/selftest-auth.sh) : ESCALE_AUTHTEST_DIR (dossier du sshd de test :
/// hostkey.pub, ppkey, client, known_hosts*, sshd.log), ESCALE_AUTHTEST_PORT, ESCALE_AUTHTEST_PASSPHRASE.
///
/// Ce que ce sshd non privilégié ne permet PAS : valider un mot de passe de compte (jamais de connexion réussie par mot de
/// passe) ni jouer une vraie 2FA (aucune invite clavier-interactif sans PAM). Les dialogues « code de vérification » et
/// « autre invite » sont donc seulement présentés (invite synthétique) et capturés, sans serveur réel derrière.
@MainActor
final class AuthSelfTest {
    let dir: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []
    private var shots: [String] = []
    private var notes: [String: String] = [:]
    private var window: NSWindow?

    private let env = ProcessInfo.processInfo.environment
    private var sshdDir: String { env["ESCALE_AUTHTEST_DIR"] ?? "" }
    private var port: Int { Int(env["ESCALE_AUTHTEST_PORT"] ?? "") ?? 0 }
    private var passphrase: String { env["ESCALE_AUTHTEST_PASSPHRASE"] ?? "" }
    private let user = NSUserName()
    private var baseExtra: [String] = []

    private var center: AuthDialogCenter { model.connections.dialogs }
    private var store: any SecretStore { model.connections.secretStore }

    init(directory: String, model: AppModel) { dir = directory; self.model = model }

    // MARK: Aides générales

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-auth] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }

    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return cond()
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    private func text(_ t: TerminalTab) -> String { t.session.engine.text(includingScrollback: true) }
    private func type(_ t: TerminalTab, _ s: String) { t.session.engine.sendInput(Data(s.utf8)) }
    private func isFailed(_ t: TerminalTab) -> Bool { if case .failed = t.status { true } else { false } }
    private func failMessage(_ t: TerminalTab) -> String { if case .failed(let m) = t.status { m } else { "" } }

    private func capture(windowNumber: Int, name: String, quiet: Bool = false) {
        let path = "\(dir)/\(name).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(windowNumber)", path]
        // screencapture échoue parfois à froid (fenêtre pas encore composée) : jusqu'à 4 essais.
        for _ in 0..<(quiet ? 1 : 4) {
            try? FileManager.default.removeItem(atPath: path)
            let q = Process()
            q.executableURL = p.executableURL; q.arguments = p.arguments
            let errPipe = Pipe(); q.standardError = errPipe
            try? q.run(); q.waitUntilExit()
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if !err.isEmpty { notes["screencapture_\(name)"] = err }
            if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png"); return }
            Thread.sleep(forTimeInterval: 0.4)
        }
        if !quiet { check("capture_\(name)", false, "screencapture n'a pas produit de fichier") }
    }

    /// Capture de la fenêtre principale (sans activer l'app).
    private func shotWindow(_ name: String) async {
        guard let win = window else { return }
        win.orderFrontRegardless()
        await sleep(0.6)
        model.workspace.activeTab?.session.engine.refreshDisplay()
        await sleep(0.2)
        capture(windowNumber: win.windowNumber, name: name)
    }

    /// Capture de la feuille attachée (dialogue, import, éditeur).
    @discardableResult
    private func shotSheet(_ name: String) async -> NSWindow? {
        guard let win = window else { return nil }
        win.orderFrontRegardless()
        _ = await wait(5) { win.attachedSheet != nil }
        await sleep(0.7)
        guard let sheet = win.attachedSheet else {
            check("feuille_\(name)_visible", false, "aucune feuille attachée")
            await shotWindow(name)
            return nil
        }
        // Une feuille n'est pas toujours capturable seule (« could not create image from window ») : la fenêtre
        // parente, qui la contient, sert alors de capture.
        let before = shots.count
        notes["etat_\(name)"] = "feuille n°\(sheet.windowNumber) visible=\(sheet.isVisible) occlusion=\(sheet.occlusionState.contains(.visible)) alpha=\(sheet.alphaValue) parent n°\(win.windowNumber) occlusion=\(win.occlusionState.contains(.visible)) espace=\(win.isOnActiveSpace)"
        capture(windowNumber: sheet.windowNumber, name: name, quiet: true)
        if shots.count == before { capture(windowNumber: win.windowNumber, name: name, quiet: true) }
        // Fenêtre sur un autre Space (l'utilisateur a changé de bureau) : screencapture ne peut rien voir ; on rend le
        // contenu de la feuille directement depuis AppKit (cacheDisplay), indépendamment de l'écran.
        if shots.count == before, let v = sheet.contentView?.superview ?? sheet.contentView,
           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                shots.append("\(name).png")
                notes["rendu_interne_\(name)"] = "cacheDisplay (fenêtre hors Space actif)"
            }
        }
        if shots.count == before { check("capture_\(name)", false, "aucune capture possible") }
        return sheet
    }

    private func children() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let me = getpid()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, Int32(f[1]) == me else { return nil }
            let name = (String(f[2]) as NSString).lastPathComponent
            return name == "ps" ? nil : "\(f[0]) \(name)"
        }
    }

    private var sshdLog: String { (try? String(contentsOfFile: "\(sshdDir)/sshd.log", encoding: .utf8)) ?? "" }
    private var acceptedCount: Int { sshdLog.components(separatedBy: "Accepted publickey").count - 1 }

    private func sha256(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    @discardableResult
    private func newHost(_ name: String, auth: HostProfile.Auth, id: UUID = UUID()) -> HostProfile {
        let h = HostProfile(id: id, name: name, host: "127.0.0.1", port: port, user: user, auth: auth, tags: ["authtest"])
        model.library.upsert(h)
        return h
    }

    /// Options ssh des PROCHAINS liens (un lien copie les options à sa création).
    private func setSSH(known: String, extra: [String] = ["PasswordAuthentication=no"]) {
        model.connections.sshOptions.userKnownHostsFile = known
        model.connections.sshOptions.strictHostKeyChecking = .ask
        model.connections.sshOptions.extraOptions = baseExtra + extra
    }

    private func closeAndWaitDown(_ tab: TerminalTab) async -> Bool {
        let link = tab.link
        model.close(tab)
        guard let link else { return true }
        return await wait(15) { link.state == .disconnected }
    }

    // MARK: Répondeur de dialogues (pilote la file sans clic)

    typealias Handler = @MainActor (AuthDialog) async -> AskpassDecision?
    private var handler: Handler?
    private var handled: [AuthDialog] = []
    private var answering = false
    private var maxSheets = 0

    private func startAnswering() {
        answering = true
        Task { @MainActor in
            var seen = Set<UUID>()
            while answering {
                maxSheets = max(maxSheets, window?.sheets.count ?? 0)
                if let d = center.current, !seen.contains(d.id), let h = handler {
                    seen.insert(d.id)
                    handled.append(d)
                    if let decision = await h(d) { center.resolve(d.id, decision) }
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    private func isPassphrase(_ d: AuthDialog) -> Bool { if case .passphrase = d.request.kind { true } else { false } }

    // MARK: Scénario

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard await wait(15, { model.mainWindow != nil }), let win = model.mainWindow else {
            check("fenetre_principale", false); return finish()
        }
        window = win
        win.orderFrontRegardless() // visible sans activer l'app ni voler le focus clavier
        guard !sshdDir.isEmpty, port > 0 else { check("environnement_sshd", false, "variables ESCALE_AUTHTEST_* absentes"); return finish() }
        center.requestsAttention = false
        model.connections.graceDelay = 0.5
        model.connections.reconnectDelays = [0.5]
        baseExtra = model.connections.sshOptions.extraOptions
        _ = await wait(10) { model.library.isLoaded }
        startAnswering()

        await scenarioLibrary()
        await scenarioSearch()
        await scenarioImport()
        await scenarioEditor()
        let p = await scenarioPassphrase()
        await scenarioReconnect(p)
        await scenarioCancel()
        await scenarioUnknownHostKey()
        await scenarioChangedHostKey()
        await scenarioPasswordPrompt()
        await scenarioConcurrent()
        await scenarioSyntheticDialogs()
        await scenarioAskpassExecutable()
        await scenarioFinal(p)
        answering = false
        return finish()
    }

    // MARK: (a) Bibliothèque

    private func scenarioLibrary() async {
        let libPath = model.options.libraryPath ?? ""
        let fm = FileManager.default
        check("a_bibliotheque_absente_au_depart", !libPath.isEmpty && model.library.loadProblem == nil && model.library.library.hosts.isEmpty)
        check("a_fichier_non_cree_avant_modification", !fm.fileExists(atPath: libPath))
        let folder = model.library.addFolder(name: "Tests auth", parentID: nil)
        let h = HostProfile(name: "Hôte initial", host: "initial.example.com", port: 2222, user: "u", tags: ["x"], folderID: folder?.id)
        model.library.upsert(h)
        await model.library.flush()
        let url = URL(fileURLWithPath: libPath)
        let json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("a_fichier_cree_au_bon_format", (json?["version"] as? Int) == FileHostRepository.currentVersion
              && (json?["hosts"] as? [Any])?.count == 1 && (json?["folders"] as? [Any])?.count == 1,
              "version=\(json?["version"] ?? "?")")
        let perms = (try? fm.attributesOfItem(atPath: libPath)[.posixPermissions] as? Int) ?? -1
        check("a_permissions_0600", perms == 0o600, String(perms, radix: 8))
        let reread = try? await FileHostRepository(url: url).load()
        check("a_relue_identique", reread == model.library.library)
        var renamed = h; renamed.name = "Hôte renommé"
        model.library.upsert(renamed)
        await model.library.flush()
        let reread2 = try? await FileHostRepository(url: url).load()
        check("a_relue_apres_modification", reread2?.hosts.first?.name == "Hôte renommé" && reread2?.folders.count == 1)
        check("a_aucun_depot_provisoire_hosts_json", !fm.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("hosts.json").path))

        // Fichiers illisibles : erreur claire, fichier intact, rien n'est écrit.
        let sub = "\(dir)/lib-tests"
        try? fm.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let cases: [(String, String, String)] = [
            ("corrompu", "{ ceci n'est pas du json", "illisible"),
            ("version-future", "{\"version\": 99, \"folders\": [], \"hosts\": []}", "récente"),
        ]
        for (label, content, expected) in cases {
            let path = "\(sub)/\(label).json"
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
            let before = Data(content.utf8)
            let store2 = LibraryStore(repository: FileHostRepository(url: URL(fileURLWithPath: path)))
            await store2.load()
            check("a_\(label)_erreur_signalee", store2.loadProblem?.contains(expected) == true, store2.loadProblem ?? "aucun message")
            store2.upsert(HostProfile(name: "ne doit pas être écrit", host: "x"))
            await store2.flush()
            check("a_\(label)_fichier_intact", fm.contents(atPath: path) == before)
            store2.startFresh()
            await store2.flush()
            let aside = ((try? fm.contentsOfDirectory(atPath: sub)) ?? []).filter { $0.hasPrefix("\(label).json.corrupt-") }
            check("a_\(label)_mis_de_cote_au_choix_utilisateur",
                  aside.count == 1 && fm.contents(atPath: "\(sub)/\(aside[0])") == before && store2.loadProblem == nil,
                  aside.joined(separator: ","))
        }
    }

    // MARK: (b) Recherche

    private func scenarioSearch() async {
        let names = ["prod-web-01", "Production DB", "staging web", "web-prod-eu", "Été backup", "bastion"]
        for n in names { model.library.upsert(HostProfile(name: n, host: n.lowercased().replacingOccurrences(of: " ", with: "-") + ".example.com", user: "ops", tags: n == "bastion" ? ["jump"] : [])) }
        let r = model.library.searchResults("prod")
        let ordered = r.map(\.host.name)
        check("b_resultats_prod", Set(ordered) == ["prod-web-01", "Production DB", "web-prod-eu"], ordered.joined(separator: " | "))
        check("b_prefixe_avant_milieu_de_mot", ordered.last == "web-prod-eu" && ordered.first != "web-prod-eu", ordered.joined(separator: " | "))
        if let first = r.first {
            let nameRanges = first.matches.first { $0.field == .name }?.ranges ?? []
            let highlighted = nameRanges.map { String(first.host.name[$0]) }
            check("b_plages_surlignage_nom", highlighted.map { $0.lowercased() } == ["prod"], "\(highlighted) dans « \(first.host.name) »")
        } else { check("b_plages_surlignage_nom", false, "aucun résultat") }
        let r2 = model.library.searchResults("wb").map(\.host.name)
        check("b_sous_sequence", r2.contains("staging web"), r2.joined(separator: " | "))
        check("b_insensible_aux_accents", model.library.searchResults("ete").first?.host.name == "Été backup")
        check("b_etiquette", model.library.searchResults("jump").first?.host.name == "bastion")
        check("b_aucun_resultat", model.library.searchResults("zzzqqq").isEmpty)
        check("b_requete_vide_aucun_resultat", model.library.searchResults("   ").isEmpty)
        model.searchText = "prod"
        await sleep(0.8)
        let rows = window?.contentView.flatMap { tableRowCount(in: $0) }
        check("b_barre_laterale_resultats_a_plat", (rows ?? 0) >= 3 && (rows ?? 99) <= 6, "lignes : \(rows.map(String.init) ?? "?")")
        await shotWindow("b-recherche-active")
        model.searchText = ""
        await sleep(0.3)
    }

    private func tableRowCount(in view: NSView) -> Int? {
        if let t = view as? NSTableView { return t.numberOfRows }
        for s in view.subviews { if let n = tableRowCount(in: s) { return n } }
        return nil
    }

    // MARK: (c) Import

    private func scenarioImport() async {
        guard let source = model.options.sshConfigImportSource else { check("c_source_import_fournie", false); return }
        let before = sha256(source)
        let mtimeBefore = (try? FileManager.default.attributesOfItem(atPath: source)[.modificationDate] as? Date) ?? nil
        // Un hôte déjà présent (même alias, réglages OpenSSH) doit être exclu.
        model.library.upsert(HostProfile(name: "alpha déjà là", host: "alpha", auth: .openSSHDefaults))
        let folder = model.library.addFolder(name: "Importés", parentID: nil)
        model.beginImport()
        guard let importer = model.importer else { check("c_feuille_ouverte", false); return }
        importer.load()
        let aliases = importer.entries.map(\.alias)
        check("c_entrees_detectees", Set(aliases) == ["alpha", "beta", "gamma"], aliases.joined(separator: ","))
        let alpha = importer.entries.first { $0.alias == "alpha" }
        check("c_apercu_hostname_user_port_proxyjump",
              alpha?.hostName == "alpha.example.com" && alpha?.user == "deploy" && alpha?.port == 2222 && alpha?.proxyJump == "bastion", "\(String(describing: alpha))")
        check("c_doublon_grise_et_decoche", alpha.map { !importer.isImportable($0) } == true && importer.selected == ["beta", "gamma"],
              "cochées : \(importer.selected.sorted())")
        check("c_avertissements_affiches", !importer.warnings.isEmpty, importer.warnings.joined(separator: " | "))
        importer.folderID = folder?.id
        await sleep(0.5)
        let sheet = await shotSheet("c-import-ssh-config")
        check("c_feuille_import_attachee", sheet != nil)
        importer.selected.remove("gamma") // l'utilisateur décoche « gamma »
        let added = importer.commit()
        await model.library.flush()
        check("c_hotes_ajoutes_au_dossier_choisi", Set(added.map(\.name)) == ["beta"] && added.allSatisfy { $0.folderID == folder?.id }, added.map(\.name).joined(separator: ","))
        check("c_pas_de_doublon_alpha", model.library.library.hosts.filter { $0.host == "alpha" }.count == 1)
        check("c_gamma_non_importe", !model.library.library.hosts.contains { $0.host == "gamma" })
        let onDisk = try? await FileHostRepository(url: URL(fileURLWithPath: model.options.libraryPath ?? "")).load()
        check("c_ajout_ecrit_sur_disque", onDisk?.hosts.contains { $0.host == "beta" && $0.folderID == folder?.id } == true)
        model.importer = nil
        await sleep(0.5)
        let mtimeAfter = (try? FileManager.default.attributesOfItem(atPath: source)[.modificationDate] as? Date) ?? nil
        check("c_source_inchangee_somme_de_controle", before != nil && before == sha256(source), "sha256 \(before?.prefix(12) ?? "?")")
        check("c_source_date_inchangee", mtimeBefore == mtimeAfter)
        let missing = ImportModel(library: model.library, source: URL(fileURLWithPath: "\(dir)/n-existe-pas.config"))
        missing.load()
        check("c_source_absente_message", missing.error != nil && !FileManager.default.fileExists(atPath: "\(dir)/n-existe-pas.config"), missing.error ?? "")
    }

    // MARK: Éditeur d'hôte (chemin de clé long, mot de passe Trousseau)

    private func scenarioEditor() async {
        let long = "/Users/someone/Documents/projets/infrastructure/clients/entreprise-exemple/production/clefs-ssh/id_ed25519_serveur_principal"
        let h = HostProfile(name: "Éditeur clé longue", host: "keys.example.com", user: "u", auth: .keyFile(path: long))
        model.library.upsert(h)
        model.editor = .editHost(h)
        await sleep(0.8)
        let sheet = await shotSheet("e-editeur-cle-longue")
        check("e_editeur_cle_longue_capture", sheet != nil)
        if let sheet {
            let titles = defaultButtons(of: sheet)
            notes["e_bouton_par_defaut_introspectable"] = "\(titles)" // SwiftUI n'expose pas le bouton par défaut : voir not_tested
        }
        model.editor = nil
        await sleep(0.6)
        let id = UUID()
        let account = AuthKeychain.passwordAccount(for: id)
        let hk = newHost("Éditeur mot de passe", auth: .keychainPassword(account: account), id: id)
        try? await store.setSecret(Secret("secret-de-test-editeur"), for: account)
        model.editor = .editHost(hk)
        await sleep(1.0)
        await shotSheet("e-editeur-mot-de-passe-trousseau")
        model.editor = nil
        await sleep(0.6)
        model.deleteHost(hk)
        var removed = false
        for _ in 0..<50 {
            if ((try? await store.secret(for: account)) ?? nil) == nil { removed = true; break }
            await sleep(0.1)
        }
        check("e_suppression_hote_supprime_son_secret", removed)
    }

    /// Titre du bouton par défaut d'une feuille (celui qu'Entrée déclenche) : cellule par défaut de la fenêtre, sinon
    /// bouton dont l'équivalent clavier est Entrée.
    private func defaultButtons(of sheet: NSWindow) -> [String] {
        if let c = sheet.defaultButtonCell { return [c.title] }
        // Boutons SwiftUI : pas de NSButton, mais l'attribut d'accessibilité AXDefaultButton de la fenêtre le désigne.
        if let el = sheet.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXDefaultButton")) as? NSObject {
            let title = el.accessibilityAttributeValue(.title) as? String ?? el.accessibilityAttributeValue(.description) as? String
            notes["ax_default_button"] = title ?? "(sans titre)"
            if let title { return [title] }
        }
        notes["ax_default_button"] = "aucun"
        let all = buttons(in: sheet.contentView)
        notes["boutons_\(all.count)"] = all.map { "\($0.title)|\($0.keyEquivalent.debugDescription)|\($0.isHighlighted)" }.joined(separator: ";")
        return all.filter { $0.keyEquivalent == "\r" }.map(\.title)
    }

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        var out = (view as? NSButton).map { [$0] } ?? []
        for s in view.subviews { out += buttons(in: s) }
        return out
    }

    // MARK: (d) Phrase de passe : mauvaise puis bonne, mémorisation, 2e connexion sans dialogue

    private func scenarioPassphrase() async -> HostProfile {
        let key = "\(sshdDir)/ppkey"
        setSSH(known: "\(sshdDir)/known_hosts")
        let p = newHost("PP mémorisée", auth: .keyFile(path: key))
        let account = AuthKeychain.passphraseAccount(for: p.id)
        var secretBeforeSuccess: Bool?
        var phraseHandled = 0
        handler = { [self] d in
            guard isPassphrase(d) else { return .cancel }
            phraseHandled += 1
            if phraseHandled == 1 {
                await shotSheet("d-dialogue-phrase-de-passe")
                return .secret(Secret("mauvaise-phrase"), remember: true)
            }
            // Deuxième invite (secret refusé) : rien ne doit être dans le Trousseau avant le succès (invariant 11).
            secretBeforeSuccess = ((try? await store.secret(for: account)) ?? nil) != nil
            await shotSheet("d-dialogue-phrase-refusee")
            return .secret(Secret(passphrase), remember: true)
        }
        let tab = model.newTab(p)
        let conn = model.connections.connection(for: p)
        let ok = await wait(40) { tab.status == .running && conn.state == .connected }
        check("d_phrase_mauvaise_puis_bonne_connecte", ok, "\(tab.status) / \(conn.state)")
        let kinds = handled.map(\.request.kind)
        check("d_dialogue_de_type_phrase_de_passe_avec_nom_de_cle",
              handled.count >= 2 && kinds.allSatisfy { $0 == .passphrase(keyPath: key) }, "\(kinds)")
        check("d_deuxieme_invite_signalee_refusee", handled.count >= 2 && handled[1].request.attempt == 2 && handled[0].request.attempt == 1)
        check("d_dialogue_propose_memorisation", handled.first?.canRemember == true)
        check("d_secret_absent_avant_succes", secretBeforeSuccess == false, "\(String(describing: secretBeforeSuccess))")
        let stored = (try? await store.secret(for: account)) ?? nil
        check("d_secret_present_apres_succes", stored == Secret(passphrase))
        type(tab, "echo AUTH-$((6*7))-${SSH_CONNECTION%% *}\r")
        check("d_shell_distant_fonctionnel", await wait(15) { text(tab).contains("AUTH-42-127.0.0.1") })
        await shotWindow("d-connecte-apres-phrase")

        // Seconde connexion après déconnexion : phrase mémorisée, AUCUN dialogue.
        check("d_deconnexion_complete", await closeAndWaitDown(tab))
        let dialogsBefore = center.presentedLog.count, handledBefore = handled.count
        let tab2 = model.newTab(p)
        let ok2 = await wait(40) { tab2.status == .running }
        check("d_seconde_connexion_reussit", ok2, "\(tab2.status)")
        check("d_seconde_connexion_sans_dialogue", center.presentedLog.count == dialogsBefore && handled.count == handledBefore && center.pendingCount == 0,
              "dialogues avant \(dialogsBefore), après \(center.presentedLog.count)")
        type(tab2, "echo SECOND-$((7*6))\r")
        check("d_seconde_connexion_shell_fonctionnel", await wait(15) { text(tab2).contains("SECOND-42") })
        return p
    }

    // MARK: Reconnexion automatique : secret mémorisé réutilisé sans dialogue ; sinon « Authentification requise »

    private func scenarioReconnect(_ p: HostProfile) async {
        guard let tab = model.workspace.tabs(forHost: p.id).first, let link = tab.link else { check("k_onglet_disponible", false); return }
        let dialogsBefore = center.presentedLog.count
        let epoch0 = link.epoch
        if let pid = await link.transport.masterProcessIdentifier { kill(pid, SIGKILL) }
        let back = await wait(40) { link.epoch > epoch0 && tab.status == .running && link.state == .connected }
        check("k_reconnexion_auto_avec_secret_memorise", back, "\(link.state) / \(tab.status) / epoch \(link.epoch)")
        check("k_reconnexion_sans_dialogue", center.presentedLog.count == dialogsBefore && center.pendingCount == 0)
        _ = await closeAndWaitDown(tab)

        // Hôte sans secret mémorisé : la reconnexion exige une saisie → « Authentification requise », aucune feuille.
        let q = newHost("PP non mémorisée", auth: .keyFile(path: "\(sshdDir)/ppkey"))
        handler = { [self] d in
            guard isPassphrase(d) else { return .cancel }
            return .secret(Secret(passphrase), remember: false)
        }
        let t = model.newTab(q)
        check("l_connexion_initiale", await wait(40) { t.status == .running }, "\(t.status)")
        guard let l = t.link else { return }
        let presented = center.presentedLog.count
        let e0 = l.epoch
        let attemptsBefore = l.connectAttempts
        if let pid = await l.transport.masterProcessIdentifier { kill(pid, SIGKILL) }
        check("l_etat_authentification_requise", await wait(40) { l.state == .authRequired }, "\(l.state)")
        check("l_bandeau_authentification_requise", await wait(5) { failMessage(t).contains("Authentification requise") }, "\(t.status)")
        check("l_aucune_feuille_ouverte_en_reconnexion", center.presentedLog.count == presented && center.pendingCount == 0 && window?.attachedSheet == nil)
        await sleep(2)
        check("l_pas_de_boucle_de_reconnexion", l.connectAttempts == attemptsBefore + 1 && l.state == .authRequired, "tentatives : \(l.connectAttempts - attemptsBefore)")
        check("l_epoque_incrementee", l.epoch > e0)
        await shotWindow("l-bandeau-authentification-requise")
        // L'utilisateur clique « Réessayer » : cette fois la feuille s'ouvre.
        model.retry(t.activePane)
        let back2 = await wait(40) { t.status == .running && l.state == .connected }
        check("l_reessayer_ouvre_le_dialogue_puis_connecte", back2 && center.presentedLog.count == presented + 1, "\(t.status) / dialogues +\(center.presentedLog.count - presented)")
        _ = await closeAndWaitDown(t)
    }

    // MARK: (e) Annulation

    private func scenarioCancel() async {
        setSSH(known: "\(sshdDir)/known_hosts")
        let c = newHost("PP annulée", auth: .keyFile(path: "\(sshdDir)/ppkey"))
        handler = { [self] _ in
            await shotSheet("e-dialogue-avant-annulation")
            return .cancel
        }
        let tab = model.newTab(c)
        _ = await wait(30) { isFailed(tab) }
        let link = tab.link
        check("e_etat_annule", link?.state == .cancelled, "\(String(describing: link?.state))")
        check("e_message_annulation", failMessage(tab).contains("annulée"), "\(tab.status)")
        let attempts = link?.connectAttempts ?? -1
        await sleep(3)
        check("e_pas_de_nouvelle_tentative", link?.connectAttempts == attempts && attempts == 1 && link?.state == .cancelled, "tentatives \(attempts)")
        check("e_aucun_dialogue_restant", center.pendingCount == 0 && window?.attachedSheet == nil)
        var kids: [String] = []
        _ = await wait(10) { kids = children().filter { $0.hasSuffix(" ssh") }; return kids.isEmpty }
        check("e_aucun_ssh_residuel", kids.isEmpty, kids.joined(separator: ", "))
        check("e_pastille_sidebar_annulee", model.connections.state(of: c.id) == .cancelled)
        await shotWindow("e-bandeau-annule")
        model.close(tab)
    }

    // MARK: (f) Clé d'hôte inconnue : empreinte exacte, accepter / refuser

    private func scenarioUnknownHostKey() async {
        let expected = run("/usr/bin/ssh-keygen", ["-l", "-f", "\(sshdDir)/hostkey.pub"]).split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let emptyKnown = "\(sshdDir)/known_hosts_vide_a"
        FileManager.default.createFile(atPath: emptyKnown, contents: Data())
        setSSH(known: emptyKnown)
        let u = newHost("Clé inconnue acceptée", auth: .keyFile(path: "\(sshdDir)/client"))
        var seen: AuthDialog?
        var defaultButton: [String] = []
        handler = { [self] d in
            seen = d
            if let sheet = await shotSheet("f-dialogue-cle-d-hote-inconnue") {
                defaultButton = defaultButtons(of: sheet)
            }
            return .accept
        }
        let tab = model.newTab(u)
        check("f_accepter_connecte", await wait(40) { tab.status == .running }, "\(tab.status)")
        if case .hostKeyConfirmation(let type, let fp, let host)? = seen?.request.kind {
            check("f_empreinte_egale_a_ssh_keygen", fp == expected && !expected.isEmpty, "dialogue \(fp ?? "nil") / ssh-keygen \(expected)")
            check("f_type_de_cle_et_hote", type?.uppercased() == "ED25519" && host?.contains("127.0.0.1") == true, "\(type ?? "nil") / \(host ?? "nil")")
        } else { check("f_dialogue_de_confirmation_de_cle", false, "\(String(describing: seen?.request.kind))") }
        notes["f_bouton_par_defaut_introspectable"] = "\(defaultButton)"
        check("f_cle_ajoutee_au_known_hosts_de_test", (try? String(contentsOfFile: emptyKnown, encoding: .utf8))?.contains("ssh-ed25519") == true)
        _ = await closeAndWaitDown(tab)

        let emptyKnown2 = "\(sshdDir)/known_hosts_vide_b"
        FileManager.default.createFile(atPath: emptyKnown2, contents: Data())
        setSSH(known: emptyKnown2)
        let r = newHost("Clé inconnue refusée", auth: .keyFile(path: "\(sshdDir)/client"))
        handler = { _ in .cancel }
        let acceptedBefore = acceptedCount
        let t2 = model.newTab(r)
        _ = await wait(30) { isFailed(t2) }
        check("f_refuser_echec_propre", t2.link?.state == .cancelled && failMessage(t2).contains("non approuvée"), "\(String(describing: t2.link?.state)) / \(t2.status)")
        check("f_refuser_known_hosts_inchange_et_pas_de_connexion", (try? String(contentsOfFile: emptyKnown2, encoding: .utf8)) == "" && acceptedCount == acceptedBefore)
        await sleep(1.5)
        check("f_refuser_pas_de_nouvelle_tentative", t2.link?.connectAttempts == 1)
        model.close(t2)
    }

    // MARK: (g) Clé d'hôte modifiée : jamais de dialogue

    private func scenarioChangedHostKey() async {
        let known = "\(sshdDir)/known_hosts_changed"
        let before = FileManager.default.contents(atPath: known)
        setSSH(known: known)
        let g = newHost("Clé modifiée", auth: .keyFile(path: "\(sshdDir)/client"))
        handler = { _ in .accept } // même un « oui » universel ne doit jamais être demandé
        let presented = center.presentedLog.count
        let tab = model.newTab(g)
        _ = await wait(30) { isFailed(tab) }
        let link = tab.link
        var msg = ""
        if case .hostKeyChanged(let m)? = link?.state { msg = m }
        check("g_etat_dedie_cle_modifiee", !msg.isEmpty, "\(String(describing: link?.state))")
        check("g_message_cite_known_hosts", msg.contains(known), msg)
        check("g_message_explicatif_francais", msg.contains("a changé") && msg.contains("refusée"))
        check("g_aucun_dialogue", center.presentedLog.count == presented && window?.attachedSheet == nil)
        check("g_known_hosts_inchange", FileManager.default.contents(atPath: known) == before)
        check("g_pastille_sidebar_rouge", { if case .hostKeyChanged = model.connections.state(of: g.id) { true } else { false } }())
        await sleep(1.5)
        check("g_pas_de_nouvelle_tentative", link?.connectAttempts == 1)
        await shotWindow("g-cle-d-hote-modifiee")
        model.close(tab)
    }

    // MARK: Mot de passe : invite réelle (sshd sans PAM : jamais accepté)

    private func scenarioPasswordPrompt() async {
        setSSH(known: "\(sshdDir)/known_hosts", extra: ["PubkeyAuthentication=no", "PreferredAuthentications=password"])
        let id = UUID()
        let h = newHost("Mot de passe Trousseau", auth: .keychainPassword(account: AuthKeychain.passwordAccount(for: id)), id: id)
        var attempts = 0
        handler = { [self] d in
            guard case .password = d.request.kind else { return .cancel }
            attempts += 1
            if attempts == 1 { await shotSheet("d-dialogue-mot-de-passe") }
            return .secret(Secret("mauvais-mot-de-passe-\(attempts)"), remember: true)
        }
        let tab = model.newTab(h)
        _ = await wait(40) { isFailed(tab) }
        let mine = handled.suffix(attempts)
        check("m_dialogue_mot_de_passe", attempts >= 1 && mine.allSatisfy { if case .password(let u) = $0.request.kind { u?.contains("127.0.0.1") == true } else { false } }, "\(attempts) invite(s) : \(mine.map(\.request.kind))")
        check("m_propose_memorisation_hote_trousseau", mine.first?.canRemember == true)
        check("m_secret_refuse_etat_echec_sans_boucle", { if case .failed = tab.link?.state ?? .disconnected { true } else { false } }() && tab.link?.connectAttempts == 1,
              "\(String(describing: tab.link?.state))")
        check("m_message_secret_refuse", failMessage(tab).contains("refusé"), "\(tab.status)")
        let kept = (try? await store.secret(for: AuthKeychain.passwordAccount(for: h.id))) ?? nil
        check("m_rien_memorise_apres_echec", kept == nil)
        check("m_mot_de_passe_jamais_dans_le_message", !failMessage(tab).contains("mauvais-mot-de-passe"))
        model.close(tab)
        model.deleteHost(h)
    }

    // MARK: (h) Deux hôtes à la fois : dialogues successifs

    private func scenarioConcurrent() async {
        setSSH(known: "\(sshdDir)/known_hosts")
        let a = newHost("Concurrent A", auth: .keyFile(path: "\(sshdDir)/ppkey"))
        let b = newHost("Concurrent B", auth: .keyFile(path: "\(sshdDir)/ppkey"))
        var snapshots: [(pending: Int, sheets: Int, presented: Int)] = []
        let startHandled = handled.count
        handler = { [self] _ in
            // Les deux hôtes demandent en même temps : le second dialogue doit attendre derrière le premier.
            _ = await wait(6) { center.pendingCount == 2 || handled.count - startHandled > 1 }
            snapshots.append((center.pendingCount, window?.sheets.count ?? 0, center.presentedLog.count))
            if snapshots.count == 1 { await shotSheet("h-deux-hotes-premier-dialogue") }
            return .secret(Secret(passphrase), remember: false)
        }
        let ta = model.newTab(a), tb = model.newTab(b)
        let ok = await wait(60) { ta.status == .running && tb.status == .running }
        check("h_deux_hotes_connectes", ok, "\(ta.status) / \(tb.status)")
        let mine = handled.suffix(handled.count - startHandled)
        check("h_deux_dialogues_pour_deux_hotes", mine.count == 2 && Set(mine.map(\.hostID)) == [a.id, b.id], mine.map(\.hostName).joined(separator: ","))
        check("h_premier_dialogue_avec_second_en_attente", snapshots.first?.pending == 2, "\(snapshots.map { "en attente \($0.pending), feuilles \($0.sheets)" })")
        check("h_jamais_deux_feuilles_simultanees", maxSheets <= 1 && snapshots.allSatisfy { $0.sheets <= 1 }, "max feuilles \(maxSheets)")
        check("h_dialogues_affiches_l_un_apres_l_autre", snapshots.count == 2 && snapshots[1].presented == snapshots[0].presented + 1, "\(snapshots.map(\.presented))")
        _ = await closeAndWaitDown(ta)
        _ = await closeAndWaitDown(tb)
    }

    // MARK: Dialogues synthétiques (aucun serveur réel derrière)

    private func scenarioSyntheticDialogs() async {
        let hostID = UUID()
        handler = nil
        func present(_ req: AskpassRequest, remember: Bool, shot: String) async {
            let task = Task { await center.present(request: req, hostID: hostID, hostName: "Serveur de démonstration", canRemember: remember) }
            await shotSheet(shot)
            if let id = center.current?.id { center.resolve(id, .cancel) }
            _ = await task.value
            await sleep(0.8)
        }
        await present(AskpassRequest(kind: .verificationCode(label: "Verification code:"), text: "(demo@serveur) Verification code: "), remember: false, shot: "d-dialogue-code-de-verification")
        await present(AskpassRequest(kind: .other, text: "Question inattendue du serveur : entrez le jeton :"), remember: false, shot: "d-dialogue-autre-invite")
        await present(AskpassRequest(kind: .password(userAtHost: "demo@serveur.example.com"), text: "demo@serveur.example.com's password: "), remember: true, shot: "d-dialogue-mot-de-passe-trousseau")
        check("s_dialogues_synthetiques_captures", shots.contains("d-dialogue-code-de-verification.png") && shots.contains("d-dialogue-autre-invite.png"), "invites synthétiques, sans serveur réel (pas de vraie 2FA testable)")
        check("s_file_vide_apres", center.pendingCount == 0)
    }

    // MARK: (i) Mode askpass de l'exécutable

    private struct FixedResponder: AskpassResponder {
        let decision: AskpassDecision
        let delay: Duration
        func respond(to request: AskpassRequest) async -> AskpassDecision {
            try? await Task.sleep(for: delay)
            return decision
        }
    }

    private func scenarioAskpassExecutable() async {
        guard let exe = Bundle.main.executablePath else { check("i_executable_connu", false); return }
        let fast = FixedResponder(decision: .secret(Secret("s3cret-askpass"), remember: false), delay: .zero)
        let (out1, code1, secs1, _) = await runAskpassChild(exe, responder: fast, prompt: "Enter passphrase for key '/tmp/demo': ")
        check("i_askpass_repond_sur_stdout", out1 == "s3cret-askpass\n" && code1 == 0, "sortie \(out1.debugDescription), code \(code1)")
        check("i_askpass_sort_vite", secs1 < 1.5, String(format: "%.0f ms", secs1 * 1000))
        notes["i_duree_ms"] = String(format: "%.0f", secs1 * 1000)
        let slow = FixedResponder(decision: .secret(Secret("x"), remember: false), delay: .milliseconds(700))
        let (_, code2, _, obs) = await runAskpassChild(exe, responder: slow, prompt: "Enter passphrase for key '/tmp/demo': ")
        check("i_aucune_fenetre_pendant_l_execution", code2 == 0 && obs.samples > 5 && obs.windows == 0, "\(obs.samples) observations, \(obs.windows) fenêtre(s)")
        check("i_pas_d_application_enregistree", obs.samples > 5 && !obs.registeredApp, "NSRunningApplication : \(obs.registeredApp)")
        let (out3, code3, _, _) = await runAskpassChild(exe, responder: FixedResponder(decision: .cancel, delay: .zero), prompt: "x's password: ")
        check("i_annulation_code_1_stdout_vide", code3 == 1 && out3.isEmpty, "code \(code3), sortie \(out3.debugDescription)")
    }

    private struct Observation { var samples = 0; var windows = 0; var registeredApp = false }

    private func runAskpassChild(_ exe: String, responder: any AskpassResponder, prompt: String) async -> (String, Int32, Double, Observation) {
        let server = AskpassServer(responder: responder)
        guard let ep = try? await server.start() else { return ("", -1, 0, Observation()) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = [prompt]
        p.environment = ["PATH": "/usr/bin:/bin", AskpassClient.socketVariable: ep.socketPath, AskpassClient.tokenVariable: ep.token]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let start = Date()
        do { try p.run() } catch { await server.stop(); return ("", -1, 0, Observation()) }
        let pid = p.processIdentifier
        var obs = Observation()
        // Garde-fou : si le mode askpass n'était pas pris en compte ce serait une seconde app complète → arrêt par pid.
        while p.isRunning, Date().timeIntervalSince(start) < 6 {
            obs.samples += 1
            if NSRunningApplication(processIdentifier: pid) != nil { obs.registeredApp = true }
            if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
                obs.windows += list.filter { ($0[kCGWindowOwnerPID as String] as? Int).map { $0 == Int(pid) } ?? false }.count
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let secs = Date().timeIntervalSince(start)
        if p.isRunning { kill(pid, SIGKILL) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        await server.stop()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus, secs, obs)
    }

    // MARK: (j) Fin : Trousseau vide, aucun processus résiduel

    private func scenarioFinal(_ p: HostProfile) async {
        let account = AuthKeychain.passphraseAccount(for: p.id)
        check("j_secret_memorise_present_avant_nettoyage", ((try? await store.secret(for: account)) ?? nil) != nil)
        model.deleteHost(p) // supprime aussi son secret
        var gone = false
        for _ in 0..<50 {
            if ((try? await store.secret(for: account)) ?? nil) == nil { gone = true; break }
            await sleep(0.1)
        }
        check("j_suppression_hote_supprime_phrase_memorisee", gone)
        var leftovers: [String] = []
        for h in model.library.library.hosts {
            for acc in [AuthKeychain.passwordAccount(for: h.id), AuthKeychain.passphraseAccount(for: h.id)] {
                if ((try? await store.secret(for: acc)) ?? nil) != nil { leftovers.append(acc) }
            }
        }
        check("j_trousseau_de_test_vide", leftovers.isEmpty, leftovers.joined(separator: ","))
        for t in model.workspace.tabs { model.close(t) }
        _ = await wait(20) { model.connections.allLinks.allSatisfy { $0.state == .disconnected || $0.state == .cancelled || $0.state.isFailure } }
        var kids: [String] = []
        _ = await wait(15) { kids = children().filter { $0.hasSuffix(" ssh") }; return kids.isEmpty }
        check("j_aucun_ssh_enfant_residuel", kids.isEmpty, kids.joined(separator: ", "))
        check("j_file_de_dialogues_vide", center.pendingCount == 0)
    }

    private func finish() -> Bool {
        let ok = !checks.isEmpty && checks.allSatisfy { $0.1 }
        let json: [String: Any] = [
            "ok": ok,
            "checks": Dictionary(checks.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a }),
            "details": Dictionary(checks.map { ($0.0, $0.2) }, uniquingKeysWith: { a, _ in a }),
            "failed": checks.filter { !$0.1 }.map(\.0),
            "screenshots": shots,
            "notes": notes,
            "not_tested": [
                "mot de passe réel du compte accepté par sshd (sshd non privilégié sans PAM : seules l'invite et le refus sont testés)",
                "2FA réelle (clavier-interactif) : dialogue présenté avec une invite synthétique, sans serveur",
                "bouton par défaut des feuilles (Annuler pour la clé d'hôte, Enregistrer pour l'éditeur) : SwiftUI ne l'expose ni en NSButton ni en AXDefaultButton ; garanti par .keyboardShortcut(.defaultAction) dans le code, non vérifié par l'auto-test",
                "icône de Dock d'un processus askpass : seulement NSRunningApplication et fenêtres du processus",
            ],
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/result.json"))
        }
        return ok
    }
}

private extension SSHLink.State {
    var isFailure: Bool {
        switch self {
        case .failed, .authRequired, .hostKeyChanged: true
        default: false
        }
    }
}
