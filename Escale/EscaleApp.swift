import SwiftUI
import AppKit

@main
struct EscaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(options: LaunchOptions.parse(CommandLine.arguments))

    var body: some Scene {
        WindowGroup {
            TerminalWindowView(model: model)
                .frame(minWidth: 480, minHeight: 300)
                .task { model.startSelfTestIfRequested() }
        }
        .defaultSize(width: 900, height: 560)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
