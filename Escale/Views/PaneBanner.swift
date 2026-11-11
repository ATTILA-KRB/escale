import SwiftUI

/// Bandeau d'état d'un panneau : barre fine HORS de la grille du terminal (au-dessus du moteur),
/// jamais superposée au texte.
struct PaneBanner: View {
    /// Hauteur en mode large (une ligne) et en mode compact (panneau étroit : texte sur deux lignes, boutons dessous).
    static let height: CGFloat = 30
    static let compactHeight: CGFloat = 66
    /// En dessous de cette largeur de panneau, le bandeau passe en mode compact.
    static let compactWidth: CGFloat = 460
    static func height(forWidth width: CGFloat) -> CGFloat { width < compactWidth ? compactHeight : height }

    let model: AppModel
    let pane: Pane

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < Self.compactWidth
            Group {
                if compact {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) { icon; message(lines: 2) }
                        HStack(spacing: 8) { Spacer(minLength: 0); actions }
                    }
                    .padding(.vertical, 5)
                } else {
                    HStack(spacing: 8) {
                        icon
                        message(lines: 1)
                        Spacer(minLength: 6)
                        actions
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .font(.callout)
        .buttonStyle(BannerButtonStyle())
        .background(Color(white: 0.15))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    /// Message (et dernière erreur en reconnexion) : retour à la ligne en mode compact, infobulle avec le texte complet.
    private func message(lines: Int) -> some View {
        let main = pane.bannerMessage ?? ""
        var detail: String?
        if case .reconnecting = pane.status, let e = pane.link?.lastError { detail = e }
        let full = [main, detail].compactMap { $0 }.joined(separator: " — ")
        return HStack(spacing: 8) {
            Text(main).lineLimit(lines).truncationMode(.tail).fixedSize(horizontal: false, vertical: lines > 1)
            if let detail, lines == 1 {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .help(full)
    }

    @ViewBuilder private var actions: some View {
        switch pane.status {
        case .reconnecting: Button("Reconnecter maintenant") { model.retry(pane) }
        case .failed: Button("Réessayer") { model.retry(pane) }
        case .ended: Button("Relancer") { model.retry(pane) }
        default: EmptyView()
        }
        Button(pane.status == .connecting ? "Annuler" : "Fermer") { model.closePane(pane) }
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
