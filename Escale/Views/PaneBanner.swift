import SwiftUI

/// Bandeau d'état d'un panneau : barre fine HORS de la grille du terminal (au-dessus du moteur),
/// jamais superposée au texte.
struct PaneBanner: View {
    static let height: CGFloat = 30
    let model: AppModel
    let pane: Pane

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(pane.bannerMessage ?? "").lineLimit(1).truncationMode(.tail)
            if case .reconnecting = pane.status, let e = pane.link?.lastError {
                Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            switch pane.status {
            case .reconnecting: Button("Reconnecter maintenant") { model.retry(pane) }
            case .failed: Button("Réessayer") { model.retry(pane) }
            case .ended: Button("Relancer") { model.retry(pane) }
            default: EmptyView()
            }
            Button(pane.status == .connecting ? "Annuler" : "Fermer") { model.closePane(pane) }
        }
        .font(.callout)
        .buttonStyle(BannerButtonStyle())
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .background(Color(white: 0.15))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var icon: some View {
        switch pane.status {
        case .connecting: ProgressView().controlSize(.small).scaleEffect(0.8)
        case .reconnecting: Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .ended: Image(systemName: "info.circle").foregroundStyle(.secondary)
        case .running: EmptyView()
        }
    }
}

/// Bouton à fond et liseré visibles (le style natif disparaît dans une vue hébergée sur fond sombre).
private struct BannerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Color.white.opacity(configuration.isPressed ? 0.28 : 0.14), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.25)))
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}
