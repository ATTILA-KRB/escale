import AppKit
import Foundation
import EscaleCore

/// Scénario automatique (`--selftest <dossier>`) : texte coloré + unicode, vim, redimensionnement
/// de la fenêtre + `stty size`, injection de saisie, titre/OSC 7, sortie du shell.
/// Passe uniquement par l'API (`sendInput`) : aucun événement clavier global, pas de prise de focus.
@MainActor
final class SelfTest {
    let dir: String
    let engine: SwiftTermEngine
    let session: TerminalSession
    private var checks: [(String, Bool, String)] = []
    private var shots: [String] = []

    init(directory: String, engine: SwiftTermEngine, session: TerminalSession) {
        dir = directory; self.engine = engine; self.session = session
    }

    private var text: String { engine.text(includingScrollback: true) }
    private func type(_ s: String) { engine.sendInput(Data(s.utf8)) }

    private func wait(_ timeout: Double = 8, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return cond()
    }
    private func waitText(_ s: String, _ timeout: Double = 8) async -> Bool { await wait(timeout) { text.contains(s) } }
    private func check(_ name: String, _ ok: Bool, _ detail: String = "") { checks.append((name, ok, detail)) }

    private func screenshot(_ name: String) async {
        guard let win = engine.view.window else { return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        engine.refreshDisplay()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let path = "\(dir)/\(name).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", path]
        try? p.run(); p.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png") }
    }

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Fenêtre
        let hasWindow = await wait(10) { engine.view.window != nil }
        check("fenetre_creee", hasWindow)
        guard hasWindow, let win = engine.view.window else { return finish() }
        win.orderFrontRegardless() // visible sans activer l'app ni voler le focus clavier
        check("metal_actif_ou_repli", true, "metal=\(engine.isUsingMetal)")

        // 0. Shell prêt
        type("PROMPT='$ '; clear\r")
        check("shell_pret", await waitText("$ "))

        // 1. Couleurs + unicode (sorties seulement : la ligne de commande tapée ne contient pas ces chaînes)
        type("printf '\\e[31mROUGE\\e[0m \\e[1;32mVERT\\e[0m \\e[38;2;255;128;0mORANGE24\\e[0m \\e[4;34mSOULIGNE\\e[0m\\n'\r")
        type("printf 'uni: %s\\n' \"$(printf '\\u00e9t\\u00e9 \\u65e5\\u672c\\u8a9e \\u2192 \\U1F680')\"\r")
        check("texte_colore", await waitText("ROUGE VERT ORANGE24 SOULIGNE"))
        check("unicode", await waitText("uni: été 日本語 → 🚀"), "")
        await screenshot("01-couleurs-unicode")

        // 2. Titre (OSC 2) et dossier courant (OSC 7)
        type("printf '\\e]2;Titre Escale\\a\\e]7;file://localhost/private/tmp\\a'\r")
        check("titre_osc2", await wait { session.title == "Titre Escale" }, session.title)
        check("osc7_dossier", await wait { session.workingDirectory?.path == "/private/tmp" }, session.workingDirectory?.absoluteString ?? "nil")

        // 3. vim puis sortie
        type("clear; vim -u NONE -N /etc/hosts; echo VIMDONE-$?\r")
        let vimUp = await waitText("/etc/hosts", 10)
        check("vim_affiche", vimUp && !text.contains("VIMDONE-0"))
        await screenshot("02-vim")
        type("\u{1b}:q!\r")
        check("vim_quitte", await waitText("VIMDONE-0", 10))

        // 4. Redimensionnement de la fenêtre + stty size
        type("clear\r")
        let before = engine.size
        // Cible toujours différente de la taille actuelle (la fenêtre peut être restaurée d'une exécution précédente).
        let cur = win.contentLayoutRect.size
        win.setContentSize(cur.width > 760 ? NSSize(width: 640, height: 400) : NSSize(width: 880, height: 520))
        let resized = await wait { engine.size != before }
        try? await Task.sleep(nanoseconds: 600_000_000)
        let after = engine.size
        check("moteur_redimensionne", resized, "\(before.columns)x\(before.rows) -> \(after.columns)x\(after.rows)")
        type("echo SZ $(stty size)\r")
        _ = await wait { text.range(of: #"SZ \d+ \d+"#, options: .regularExpression) != nil }
        var reported = "?"
        if let r = text.range(of: #"SZ \d+ \d+"#, options: .regularExpression) { reported = String(text[r]) }
        check("stty_size_suit_la_fenetre", reported == "SZ \(after.rows) \(after.columns)", "stty: \(reported), moteur: \(after.rows) \(after.columns)")
        await screenshot("03-redimensionne")

        // 5. Injection de saisie via sendInput
        type("echo INJECTED-$((6*7))\r")
        check("sendInput", await waitText("INJECTED-42"))
        await screenshot("04-saisie-injectee")

        // 6. Fin du processus
        type("exit\r")
        let ended = await wait { if case .finished = session.state { return true } else { return false } }
        check("processus_termine_code_0", ended && session.state == .finished(.exited(0)), session.statusText ?? "en cours")
        try? await Task.sleep(nanoseconds: 300_000_000)
        await screenshot("05-termine")
        return finish()
    }

    private func finish() -> Bool {
        session.kill()
        let ok = !checks.isEmpty && checks.allSatisfy { $0.1 }
        let json: [String: Any] = [
            "ok": ok,
            "metal": engine.isUsingMetal,
            "finalSize": "\(engine.size.columns)x\(engine.size.rows)",
            "checks": Dictionary(uniqueKeysWithValues: checks.map { ($0.0, $0.1) }),
            "details": Dictionary(uniqueKeysWithValues: checks.map { ($0.0, $0.2) }),
            "screenshots": shots,
            "bufferTail": String(text.suffix(1500)),
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/result.json"))
        }
        return ok
    }
}
