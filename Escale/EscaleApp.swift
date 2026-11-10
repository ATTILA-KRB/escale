import SwiftUI
import AppKit
import EscaleCore

/// Vrai point d'entrée. L'app est son propre `SSH_ASKPASS` : quand ssh la relance avec ESCALE_ASKPASS_SOCKET et
/// ESCALE_ASKPASS_TOKEN, elle répond à l'invite et quitte AVANT toute initialisation AppKit/SwiftUI
/// (ni fenêtre, ni icône de Dock). Sans ces variables, `runIfRequested()` ne fait rien et l'app démarre normalement.
@main
enum Launcher {
    static func main() {
        AskpassClient.runIfRequested()
        EscaleApp.main()
    }
}

struct EscaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let m = AppModel(options: LaunchOptions.parse(CommandLine.arguments))
        _model = State(initialValue: m)
        AppDelegate.model = m
    }

    var body: some Scene {
        Window("Escale", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 760, minHeight: 440)
                .task { await model.start() }
        }
        .defaultSize(width: 1180, height: 720)
        .commands { EscaleCommands(model: model) }
    }
}

struct EscaleCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // Fichier : remplace « Nouvelle fenêtre » (fenêtre unique) et « Fermer ».
        CommandGroup(replacing: .newItem) {
            Button("Nouveau terminal local") { model.openLocalTab() }.keyboardShortcut("t")
            Button("Nouvel hôte…") { model.editor = .newHost(folder: nil) }.keyboardShortcut("n")
            Button("Nouveau dossier…") { model.editor = .newFolder(parent: nil) }
            Divider()
            Button("Importer depuis ~/.ssh/config…") { model.beginImport() }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Fermer l'onglet") {
                // Dernier onglet fermé : Cmd-W ferme alors la fenêtre.
                if model.workspace.activeTab != nil { model.closeActiveTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
        }
        CommandMenu("Onglets") {
            Button("Onglet suivant") { model.workspace.selectNext() }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Onglet précédent") { model.workspace.selectPrevious() }.keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1...9, id: \.self) { i in
                Button("Onglet \(i)") { model.workspace.select(index: i - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitter : tous les pty tués et tous les maîtres déconnectés avant la sortie (aucun ssh résiduel).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        Task { @MainActor in
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
