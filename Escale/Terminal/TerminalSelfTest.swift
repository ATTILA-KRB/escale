import AppKit
import ApplicationServices
import Foundation
import EscaleCore

/// `--selftest-terminal <dossier>` : saisie composée (IME, touches mortes) et accessibilité du terminal.
///
/// Piloté par l'API interne uniquement : on appelle `setMarkedText`/`insertText`/`unmarkText`/`doCommand` sur le
/// `NSTextInputClient` de la vue comme le ferait une méthode de saisie, et on lit les octets reçus par le délégué ET
/// par un vrai pty (python en mode raw qui renvoie ce qu'il lit en hexadécimal). Aucun événement clavier global :
/// changer la source de saisie ou envoyer des CGEvent volerait le focus de l'utilisateur.
/// L'accessibilité est lue par l'API AXUIElement de l'app elle-même (appel direct dans le processus : les
/// méthodes de la vue sont exécutées sur le fil appelant, qui doit donc être le fil principal).
@MainActor
final class TerminalSelfTest {
    let dir: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []
    private var notes: [String: String] = [:]
    private var shots: [String] = []

    init(directory: String, model: AppModel) { dir = directory; self.model = model }

    // MARK: Aides

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-terminal] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }
    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 30_000_000) }
        return cond()
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func ms(_ t0: Date) -> Double { (Date().timeIntervalSince(t0) * 1000 * 100).rounded() / 100 }

    /// Reçoit la saisie du moteur et la transmet au pty de test.
    @MainActor
    private final class Recorder: TerminalEngineDelegate {
        var bytes = Data()
        var pty: PTYProcess?
        func terminal(_ engine: any TerminalEngine, didProduceInput b: Data) { bytes.append(b); pty?.write(b) }
        func terminal(_ engine: any TerminalEngine, didResize size: TerminalSize) {}
        func terminal(_ engine: any TerminalEngine, didChangeTitle title: String) {}
        func terminal(_ engine: any TerminalEngine, didChangeWorkingDirectory url: URL) {}
    }

    private static let none = NSRange(location: NSNotFound, length: 0)

    private func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    // MARK: Lecture AX (fil secondaire)

    private struct AXReport: Sendable {
        var trusted = false
        var found = false
        var role = "", roleDescription = "", description = "", value = ""
        var numberOfCharacters = -1
        var selectedText = ""
        var visible = [-1, -1]
        var selectedRange = [-1, -1]
        var notificationSeen = false
    }
    private struct SendableAX: @unchecked Sendable { let element: AXUIElement }

    nonisolated private static func axString(_ e: AXUIElement, _ a: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
        return v as? String
    }
    nonisolated private static func axRange(_ e: AXUIElement, _ a: String) -> [Int]? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success, let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return [r.location, r.length]
    }
    nonisolated private static func findTextArea(_ e: AXUIElement, depth: Int) -> AXUIElement? {
        if axString(e, kAXRoleAttribute) == kAXTextAreaRole,
           (axString(e, kAXDescriptionAttribute) ?? "").hasPrefix("Terminal") { return e }
        guard depth > 0 else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success,
              let kids = v as? [AXUIElement] else { return nil }
        for k in kids { if let f = findTextArea(k, depth: depth - 1) { return f } }
        return nil
    }
    nonisolated private static func readAX(pid: pid_t, label: String) -> AXReport {
        var rep = AXReport()
        rep.trusted = AXIsProcessTrusted()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        var wins: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success,
              let list = wins as? [AXUIElement] else { return rep }
        for w in list {
            guard let el = findTextArea(w, depth: 8) else { continue }
            guard axString(el, kAXDescriptionAttribute) == label else { continue }
            rep.found = true
            rep.role = axString(el, kAXRoleAttribute) ?? ""
            rep.roleDescription = axString(el, kAXRoleDescriptionAttribute) ?? ""
            rep.description = axString(el, kAXDescriptionAttribute) ?? ""
            rep.value = axString(el, kAXValueAttribute) ?? ""
            var n: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &n) == .success { rep.numberOfCharacters = (n as? Int) ?? -1 }
            rep.selectedText = axString(el, kAXSelectedTextAttribute) ?? ""
            rep.visible = axRange(el, kAXVisibleCharacterRangeAttribute) ?? [-1, -1]
            rep.selectedRange = axRange(el, kAXSelectedTextRangeAttribute) ?? [-1, -1]
            return rep
        }
        return rep
    }

    // MARK: Scénario

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Fenêtre et moteur dédiés : visibles sans activer l'app ni voler le focus.
        let engine = SwiftTermEngine()
        engine.accessibilityLabel = "Terminal — Hôte Recette"
        let win = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 820, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.title = "Escale — recette terminal"
        win.isReleasedWhenClosed = false
        win.contentView = engine.view
        win.orderFrontRegardless()
        win.makeFirstResponder(engine.view)
        let rec = Recorder()
        engine.delegate = rec
        engine.forceAccessibilityNotifications(true)
        check("fenetre_creee", await wait { engine.view.window != nil && engine.size.columns > 10 }, "\(engine.size)")

        // pty réel : python en mode raw qui renvoie chaque lecture en hexadécimal.
        let py = "import os,tty\ntty.setraw(0)\nos.write(1,b'READY\\r\\n')\nwhile True:\n d=os.read(0,4096)\n if not d: break\n os.write(1,('HEX:'+d.hex()+'\\r\\n').encode())\n"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["LANG"] = "en_US.UTF-8"
        var ptyOK = false
        do {
            let p = try PTYProcess(executable: "/usr/bin/python3", arguments: ["-u", "-c", py], environment: env, columns: engine.size.columns, rows: engine.size.rows)
            rec.pty = p
            Task { @MainActor in for await chunk in p.output { engine.feed(chunk) } }
            ptyOK = await wait(15) { engine.text(includingScrollback: true).contains("READY") }
        } catch { check("pty_lance", false, "\(error)") }
        check("pty_pret", ptyOK, String(engine.text(includingScrollback: true).suffix(200)))
        guard ptyOK else { return finish() }

        let client = engine.textInputClient
        var expectedAll = Data()
        // Applique `step`, puis vérifie les octets reçus par le délégué (et rien avant `step` si `silent`).
        func expectBytes(_ name: String, _ expected: [UInt8], _ detail: String = "") {
            let got = rec.bytes
            check(name, got == Data(expected), "reçu \(hex(got)), attendu \(hex(Data(expected)))\(detail.isEmpty ? "" : " — " + detail)")
            expectedAll.append(Data(expected))
            rec.bytes = Data()
        }
        func expectSilence(_ name: String) {
            check(name, rec.bytes.isEmpty, "octets parasites : \(hex(rec.bytes))")
            rec.bytes = Data()
        }
        let suppressedBefore = engine.suppressedOutputCount

        // 1. Touches mortes AZERTY : ^ puis e → ê ; ¨ puis i → ï
        client.setMarkedText("^", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.none)
        check("dead_circ_texte_marque", client.hasMarkedText() && engine.isComposing)
        expectSilence("dead_circ_aucun_octet_pendant_composition")
        client.insertText("ê", replacementRange: Self.none)
        check("dead_circ_fin_composition", !client.hasMarkedText() && !engine.isComposing)
        expectBytes("dead_circ_e_donne_ecirc_c3aa", [0xc3, 0xaa])

        client.setMarkedText("¨", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.none)
        expectSilence("dead_trema_aucun_octet_pendant_composition")
        client.insertText("ï", replacementRange: NSRange(location: 0, length: 1)) // remplace la marque, comme AppKit
        expectBytes("dead_trema_i_donne_iuml_c3af", [0xc3, 0xaf])

        // Touche morte suivie d'une touche sans combinaison : AppKit valide « ^x » en une fois.
        client.setMarkedText("^", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.none)
        client.insertText("^x", replacementRange: Self.none)
        expectBytes("dead_circ_x_donne_circ_puis_x", [0x5e, 0x78])

        // Touche morte doublée (^^) → un seul ^ ; validation par NSAttributedString.
        client.setMarkedText("^", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.none)
        client.insertText(NSAttributedString(string: "^"), replacementRange: Self.none)
        expectBytes("dead_circ_double_via_attributedstring", [0x5e])

        // Touche morte annulée par Échap : IME retire la marque (setMarkedText vide), rien n'est envoyé.
        client.setMarkedText("^", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.none)
        client.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: Self.none)
        check("dead_annulee_plus_de_marque", !client.hasMarkedText() && !engine.isComposing)
        expectSilence("dead_annulee_aucun_octet")

        // 2. CJK — japonais : kana en cours, conversion, validation (texte simple puis attribué)
        func marked(_ s: String, clause: Bool = true) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0])
        }
        for step in ["に", "にほ", "にほん"] {
            client.setMarkedText(marked(step), selectedRange: NSRange(location: (step as NSString).length, length: 0), replacementRange: Self.none)
        }
        expectSilence("jp_kana_aucun_octet_pendant_composition")
        client.setMarkedText(marked("日本"), selectedRange: NSRange(location: 0, length: 2), replacementRange: Self.none) // conversion
        let sel = client.selectedRange(), mk = client.markedRange()
        check("jp_intervalles_coherents", mk.length == 2 && sel.location >= mk.location && sel.location + sel.length <= mk.location + mk.length,
              "marqué \(mk) sélection \(sel)")
        let sub = client.attributedSubstring(forProposedRange: mk, actualRange: nil)?.string
        check("jp_texte_marque_lisible_par_l_ime", sub == "日本", sub ?? "nil")
        expectSilence("jp_conversion_aucun_octet")
        client.insertText("日本", replacementRange: Self.none)
        expectBytes("jp_validation_donne_e697a5e69cac", [0xe6, 0x97, 0xa5, 0xe6, 0x9c, 0xac])
        check("jp_marque_levee_apres_validation", !client.hasMarkedText() && client.markedRange().location == NSNotFound)

        // validation par NSAttributedString (cas où SwiftTerm ignorait le texte)
        client.setMarkedText(marked("かな"), selectedRange: NSRange(location: 2, length: 0), replacementRange: Self.none)
        client.insertText(NSAttributedString(string: "仮名"), replacementRange: Self.none)
        expectBytes("jp_validation_attribuee_donne_e4bbaee5908d", [0xe4, 0xbb, 0xae, 0xe5, 0x90, 0x8d])

        // 3. CJK — chinois pinyin : « ni hao » → 你好
        client.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: Self.none)
        client.setMarkedText("ni hao", selectedRange: NSRange(location: 6, length: 0), replacementRange: Self.none)
        expectSilence("zh_pinyin_aucun_octet_pendant_composition")
        client.insertText("你好", replacementRange: Self.none)
        expectBytes("zh_validation_donne_e4bda0e5a5bd", [0xe4, 0xbd, 0xa0, 0xe5, 0xa5, 0xbd])

        // 4. Commandes de l'IME pendant la composition : elles lui appartiennent (aucun octet vers l'hôte)
        client.setMarkedText("ひら", selectedRange: NSRange(location: 2, length: 0), replacementRange: Self.none)
        let view = engine.view
        for sel in [#selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.cancelOperation(_:)),
                    #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveUp(_:))] {
            view.doCommand(by: sel)
        }
        expectSilence("commandes_ime_pendant_composition_aucun_octet")
        check("commandes_ime_comptees_comme_retenues", engine.suppressedOutputCount - suppressedBefore >= 5, "retenues \(engine.suppressedOutputCount - suppressedBefore)")
        client.unmarkText()
        check("unmark_leve_la_composition", !client.hasMarkedText() && !engine.isComposing)
        expectSilence("unmark_n_envoie_rien")
        // Hors composition, les mêmes commandes fonctionnent à nouveau.
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        expectBytes("hors_composition_retour_arriere_envoye_7f", [0x7f])
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        expectBytes("hors_composition_retour_chariot_envoye_0d", [0x0d])
        // Saisie programmée (macros, diffusion) jamais filtrée, même si une composition traîne.
        client.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.none)
        engine.sendInput(Data("ls\r".utf8))
        expectBytes("saisie_programmee_non_filtree", [0x6c, 0x73, 0x0d])
        client.unmarkText()
        // Frappe réelle sans IME (Ctrl-C) : chemin clavier normal intact.
        if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: win.windowNumber,
                                     context: nil, characters: "\u{03}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) {
            engine.view.keyDown(with: ev)
        }
        expectBytes("ctrl_c_reel_donne_03", [0x03])

        // 5. Les mêmes octets, de bout en bout, à travers le pty
        let wantHex = hex(expectedAll)
        let atEnd = await wait(10) {
            let t = engine.text(includingScrollback: true)
            let got = t.split(separator: "\n").compactMap { l -> String? in
                guard let r = l.range(of: "HEX:") else { return nil }
                return String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }.joined()
            return got == wantHex
        }
        let ptyText = engine.text(includingScrollback: true)
        check("pty_recoit_exactement_les_memes_octets", atEnd, "attendu \(wantHex) ; écran : \(String(ptyText.suffix(400)))")
        check("pty_aucun_octet_parasite_ef_bf_bd", !ptyText.contains("efbfbd"))

        // 6. Position du panneau de candidats : firstRect suit le curseur
        engine.feed(Data("\u{1b}[2J\u{1b}[3;5H".utf8))
        await sleep(0.4); engine.refreshDisplay(); await sleep(0.2)
        let r1 = client.firstRect(forCharacterRange: Self.none, actualRange: nil)
        engine.feed(Data("\u{1b}[9;45H".utf8))
        await sleep(0.4); engine.refreshDisplay(); await sleep(0.2)
        client.setMarkedText(marked("にほん"), selectedRange: NSRange(location: 3, length: 0), replacementRange: Self.none)
        let r2 = client.firstRect(forCharacterRange: NSRange(location: 0, length: 3), actualRange: nil)
        let cellH = engine.cellHeight
        let cellW = engine.view.bounds.width / CGFloat(max(1, engine.size.columns))
        let winFrame = win.frame
        check("firstrect_dans_la_fenetre", winFrame.insetBy(dx: -2, dy: -2).contains(r2) && r2.height > 0 && r1.height > 0, "\(r2) dans \(winFrame)")
        check("firstrect_hauteur_une_ligne", abs(r2.height - cellH) <= 3, "hauteur \(r2.height) ligne \(cellH)")
        check("firstrect_suit_la_colonne", abs((r2.minX - r1.minX) - 40 * cellW) <= 3 * cellW, "dx \(r2.minX - r1.minX) attendu \(40 * cellW)")
        check("firstrect_suit_la_ligne", abs((r1.minY - r2.minY) - 6 * cellH) <= 2 * cellH, "dy \(r1.minY - r2.minY) attendu \(6 * cellH)")
        notes["firstrect"] = "r1=\(r1) r2=\(r2) cellule=\(cellW)x\(cellH)"
        await shot("01-composition-japonaise", win, engine)
        client.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: Self.none)
        expectSilence("fin_composition_visuelle_aucun_octet")

        // 7. Accessibilité — contenu, vérifié par l'API AXUIElement de l'app elle-même
        engine.feed(Data("\u{1b}[2J\u{1b}[H".utf8))
        for i in 1...40 { engine.feed(Data("ligne-\(i) é日本\r\n".utf8)) }
        engine.feed(Data("dernier-marqueur".utf8))
        win.makeFirstResponder(engine.view)
        await sleep(0.3)
        let label = "Terminal — Hôte Recette"
        let pid = getpid()
        let ax = Self.readAX(pid: pid, label: label)
        notes["ax_trusted"] = "\(ax.trusted)"
        check("ax_element_trouve_par_AXUIElement", ax.found, "AXIsProcessTrusted=\(ax.trusted)")
        check("ax_role_textarea", ax.role == "AXTextArea", ax.role)
        check("ax_role_description", !ax.roleDescription.isEmpty, ax.roleDescription)
        check("ax_libelle_terminal_hote", ax.description == label, ax.description)
        check("ax_valeur_contient_le_texte_visible", ax.value.contains("ligne-40 é日本") && ax.value.contains("dernier-marqueur"), String(ax.value.suffix(80)))
        check("ax_nombre_de_caracteres_egal_longueur_utf16", ax.numberOfCharacters == (ax.value as NSString).length && ax.numberOfCharacters > 0, "\(ax.numberOfCharacters) / \((ax.value as NSString).length)")
        check("ax_plage_visible_valide", ax.visible[0] >= 0 && ax.visible[0] + ax.visible[1] <= ax.numberOfCharacters && ax.visible[1] > 0, "\(ax.visible)")
        check("ax_plage_selection_curseur_en_fin", ax.selectedRange[1] == 0 && ax.selectedRange[0] == ax.numberOfCharacters, "\(ax.selectedRange)/\(ax.numberOfCharacters)")
        check("ax_texte_selectionne_vide_sans_selection", ax.selectedText.isEmpty, ax.selectedText)

        // Sélection (sur la vue : la sélection souris réelle n'est pas pilotée)
        engine.selectAll()
        await sleep(0.2)
        let ax2 = Self.readAX(pid: pid, label: label)
        check("ax_texte_selectionne", ax2.selectedText.contains("ligne-40") && ax2.selectedText.contains("dernier-marqueur"), String(ax2.selectedText.suffix(60)))
        check("ax_plage_selectionnee_dans_la_valeur", ax2.selectedRange[1] > 0 && ax2.selectedRange[0] + ax2.selectedRange[1] <= ax2.numberOfCharacters, "\(ax2.selectedRange)")
        engine.clearSelection()

        // Libellé posé par Pane (hôte)
        let pane = Pane(kind: .local(command: nil), baseTitle: "prod-db")
        check("pane_libelle_terminal_hote", pane.session.engine.accessibilityLabel == "Terminal — prod-db", pane.session.engine.accessibilityLabel)
        check("pane_role_via_nsaccessibility", pane.session.engine.view.accessibilityRole() == .textArea)

        // 8. Perf : scrollback de 100 000 lignes, jamais d'instantané complet
        let big = SwiftTermEngine(scrollback: 100_000)
        big.forceAccessibilityNotifications(true)
        let bigWin = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        bigWin.isReleasedWhenClosed = false
        bigWin.contentView = big.view
        bigWin.orderFrontRegardless()
        let line = String(repeating: "x", count: 100) + "\r\n"
        let chunk = Data(String(repeating: line, count: 1000).utf8)
        let fedAt = Date()
        for _ in 0..<110 { big.feed(chunk) }   // 110 000 lignes
        notes["alimentation_110k_lignes_ms"] = "\(ms(fedAt))"
        big.feed(Data("fin-du-flux".utf8))
        let mem0 = footprintMiB()
        let rebuild0 = big.accessibilityRebuildCount
        let t0 = Date()
        let v = big.view.accessibilityValue() as? String ?? ""
        let firstQuery = ms(t0)
        let mem1 = footprintMiB()
        let lines = v.split(separator: "\n", omittingEmptySubsequences: false).count
        check("perf_valeur_bornee_en_lignes", lines <= 200 + big.size.rows + 2 && v.contains("fin-du-flux"), "\(lines) lignes, \(v.utf8.count) octets")
        check("perf_pas_d_instantane_complet_memoire", mem1 - mem0 < 50, "empreinte +\(String(format: "%.1f", mem1 - mem0)) Mio (instantané complet ≈ 500 Mio)")
        check("perf_premiere_requete_rapide", firstQuery < 100, "\(firstQuery) ms")
        let t1 = Date()
        for _ in 0..<50 { _ = big.view.accessibilityValue(); _ = big.view.accessibilityNumberOfCharacters(); _ = big.view.accessibilityVisibleCharacterRange() }
        check("perf_requetes_repetees_sans_reconstruction", big.accessibilityRebuildCount == rebuild0 + 1, "reconstructions \(big.accessibilityRebuildCount - rebuild0) ; 150 requêtes en \(ms(t1)) ms")
        // 5 000 « frappes » : aucune reconstruction tant que VoiceOver ne lit pas.
        let nBefore = big.accessibilityRebuildCount
        let k0 = Date()
        for _ in 0..<5000 { big.feed(Data("a".utf8)) }
        let perKey = ms(k0) / 5000
        check("perf_frappes_sans_reconstruction", big.accessibilityRebuildCount == nBefore, "reconstructions \(big.accessibilityRebuildCount - nBefore)")
        notes["feed_par_octet_ms"] = "\(perKey)"
        notes["premiere_requete_ax_ms"] = "\(firstQuery)"
        notes["empreinte_delta_mio"] = String(format: "%.1f", mem1 - mem0)

        // 9. Notifications limitées en fréquence : 5 000 écritures étalées sur ~1,5 s
        let n0 = engine.accessibilityNotificationCount
        let burst0 = Date()
        while Date().timeIntervalSince(burst0) < 1.5 {
            for _ in 0..<50 { engine.feed(Data("z".utf8)) }
            await sleep(0.01)
        }
        await sleep(0.7)
        let posted = engine.accessibilityNotificationCount - n0
        check("notifications_limitees_en_frequence", posted >= 2 && posted <= 6, "\(posted) notifications pour ~\(Int(ms(burst0) / 1000 * 100)) écritures/s sur 1,5 s")
        await sleep(0.7)
        let quiet0 = engine.accessibilityNotificationCount
        await sleep(0.8)
        check("notifications_aucune_au_repos", engine.accessibilityNotificationCount == quiet0)

        bigWin.close()
        win.close()

        // 10. Bannière d'accueil du terminal local (`--local-banner on` dans la recette) : écrite dans l'écran avant le
        // shell, jamais envoyée au shell ; une commande explicite n'en a pas.
        if model.options.value("local-banner") == "on", let main = model.mainWindow {
            let local = model.openLocalTab()
            let t = { local.session.engine.text(includingScrollback: true) }
            let seen = await wait(10) { t().contains("client SSH pour macOS") }
            check("banniere_terminal_local", seen && t().contains(WelcomeBanner.logo[0]), String(t().prefix(200)))
            check("banniere_shell_actif", await wait(10) { local.status == .running })
            await sleep(1.0)
            await shot("10-banniere-terminal-local", main, local.session.engine)
            let cmd = model.openLocalTab(command: ["/bin/sh"])
            await sleep(0.8)
            check("banniere_absente_pour_une_commande", !cmd.session.engine.text(includingScrollback: true).contains("ESCALE")
                  && !cmd.session.engine.text(includingScrollback: true).contains("client SSH pour macOS"))
            model.close(cmd)
            model.close(local)
        }
        notes["non_teste"] = "clavier AZERTY réel (CGEvent/changement de source de saisie : volerait le focus et modifierait les réglages de l'utilisateur) ; panneau de candidats dessiné par l'IME système ; lecture par VoiceOver réel ; sélection à la souris"
        return finish()
    }

    private func shot(_ name: String, _ win: NSWindow, _ engine: SwiftTermEngine) async {
        win.orderFrontRegardless()
        await sleep(0.5)
        for _ in 0..<3 { engine.refreshDisplay(); await sleep(0.15) }
        let path = "\(dir)/\(name).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", path]
        try? p.run(); p.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png") }
    }

    private func finish() -> Bool {
        let ok = !checks.isEmpty && checks.allSatisfy { $0.1 }
        let json: [String: Any] = [
            "ok": ok,
            "checks": Dictionary(checks.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 }),
            "details": Dictionary(checks.map { ($0.0, $0.2) }, uniquingKeysWith: { $1 }),
            "failed": checks.filter { !$0.1 }.map(\.0),
            "screenshots": shots,
            "notes": notes,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/result.json"))
        }
        return ok
    }
}
