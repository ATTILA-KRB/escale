import SwiftUI
import AppKit

/// Fenêtre minimale : la vue du terminal + bandeau d'état quand le processus est terminé.
struct TerminalWindowView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TerminalHost(engine: model.engine)
            if let text = model.session?.statusText {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.bar)
            } else if let err = model.launchError {
                Text(err).foregroundStyle(.red).padding(8)
            }
        }
        .navigationTitle(model.session?.title ?? "Escale")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.windowClosing()
        }
    }
}

/// Héberge la vue du moteur ; donne le focus clavier dès l'insertion dans une fenêtre.
private struct TerminalHost: NSViewRepresentable {
    let engine: SwiftTermEngine

    func makeNSView(context: Context) -> HostView { HostView(engine: engine) }
    func updateNSView(_ nsView: HostView, context: Context) {}

    final class HostView: NSView {
        private let engine: SwiftTermEngine
        init(engine: SwiftTermEngine) {
            self.engine = engine
            super.init(frame: .zero)
            engine.view.frame = bounds
            engine.view.autoresizingMask = [.width, .height]
            addSubview(engine.view)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // Après la fin du cycle de mise en place de la fenêtre.
            DispatchQueue.main.async { [engine] in MainActor.assumeIsolated { engine.focus() } }
        }
    }
}
