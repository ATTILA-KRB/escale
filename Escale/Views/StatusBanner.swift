import SwiftUI

/// Ton d'un bandeau : couleur du liseré, de l'icône et du bouton principal.
enum BannerTone {
    /// Information neutre (session terminée).
    case neutral
    /// Information (connexion en cours, mode dégradé assumé).
    case info
    /// Problème récupérable (reconnexion, sauvegarde impossible).
    case warning
    /// Échec.
    case error
    /// État actif qui capte la saisie (diffusion, enregistrement de macro) : fond plein, texte blanc.
    case live

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: .blue
        case .warning: .orange
        case .error, .live: .red
        }
    }

    /// Variante foncée (icône et bouton principal) : l'orange système manque de contraste sur fond clair.
    var strongColor: Color {
        switch self {
        case .neutral: Color(nsColor: .darkGray)
        case .warning: Color.orange.mix(with: .black, by: 0.3)
        case .live: .red
        case .info, .error: color.mix(with: .black, by: 0.12)
        }
    }
}

/// Icône de tête : symbole SF ou indicateur d'activité.
enum BannerIcon {
    case symbol(String)
    case progress
}

/// Bandeau d'état commun (panneaux, diffusion, macros, SFTP, bibliothèque) : icône, message, détail, boutons.
/// Disposition large sur une ligne (boutons à droite, principal en dernier) ; compacte sur deux rangées
/// (message puis boutons, alignés sous le texte). `.automatic` choisit selon la largeur idéale du contenu.
/// Boutons : `.buttonStyle(.bannerPrimary)` / `.buttonStyle(.bannerSecondary)` (style propre : le style natif
/// disparaît dans une vue AppKit hébergée sur fond sombre).
struct StatusBanner<Actions: View>: View {
    enum Layout { case automatic, wide, compact }

    let tone: BannerTone
    let icon: BannerIcon?
    let title: String
    var detail: String?
    var layout: Layout = .automatic
    /// Lignes du message en mode compact (`nil` : sans limite, hauteur libre).
    var titleLines: Int? = 2
    var detailLines: Int? = 1
    /// Occupe toute la hauteur proposée (bandeau à hauteur fixe posé par AppKit).
    var fillsHeight = false
    var onDismiss: (() -> Void)?
    @ViewBuilder var actions: () -> Actions

    /// Largeur réservée à l'icône (les boutons du mode compact s'alignent sur le texte).
    static var iconWidth: CGFloat { 16 }

    var body: some View {
        Group {
            switch layout {
            case .wide: wide
            case .compact: compact
            case .automatic: ViewThatFits(in: .horizontal) { wide; compact }
            }
        }
        .font(.callout)
        .padding(.leading, 12).padding(.trailing, 10)
        .padding(.vertical, layout == .wide ? 0 : 7)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .leading)
        .foregroundStyle(tone == .live ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .background { background }
        .environment(\.bannerTone, tone)
        .help([title, detail].compactMap { $0 }.joined(separator: " — "))
        .accessibilityElement(children: .contain)
    }

    private var wide: some View {
        HStack(spacing: 8) {
            iconView
            Text(title).lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(secondaryStyle).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions() }.fixedSize()
            dismissButton
        }
        .frame(minHeight: 30)
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                iconView
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(titleLines).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: titleLines == nil)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(secondaryStyle).lineLimit(detailLines)
                            .fixedSize(horizontal: false, vertical: detailLines == nil)
                    }
                }
                Spacer(minLength: 0)
                dismissButton
            }
            if Actions.self != EmptyView.self {
                HStack(spacing: 8) { actions() }
                    .padding(.leading, icon == nil ? 0 : Self.iconWidth + 8)
            }
        }
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .symbol(let name)?:
            Image(systemName: name)
                .foregroundStyle(tone == .live ? Color.white : tone.strongColor)
                .frame(width: Self.iconWidth)
        case .progress?:
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: Self.iconWidth, height: 14)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var dismissButton: some View {
        if let onDismiss {
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(secondaryStyle)
                .help("Masquer")
                .accessibilityLabel("Masquer")
        }
    }

    private var secondaryStyle: AnyShapeStyle {
        tone == .live ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    @ViewBuilder private var background: some View {
        if tone == .live {
            tone.color
        } else {
            ZStack(alignment: .leading) {
                Color(nsColor: .windowBackgroundColor)
                tone.color.opacity(tone == .neutral ? 0.06 : 0.11)
                Rectangle().fill(tone.color).frame(width: 3)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
        }
    }
}

extension StatusBanner where Actions == EmptyView {
    init(tone: BannerTone, icon: BannerIcon?, title: String, detail: String? = nil, layout: Layout = .automatic,
         titleLines: Int? = 2, detailLines: Int? = 1, onDismiss: (() -> Void)? = nil) {
        self.init(tone: tone, icon: icon, title: title, detail: detail, layout: layout, titleLines: titleLines,
                  detailLines: detailLines, onDismiss: onDismiss) { EmptyView() }
    }
}

// MARK: - Boutons

private struct BannerToneKey: EnvironmentKey { static let defaultValue: BannerTone = .info }

extension EnvironmentValues {
    var bannerTone: BannerTone {
        get { self[BannerToneKey.self] }
        set { self[BannerToneKey.self] = newValue }
    }
}

/// Bouton de bandeau : principal (plein, couleur du ton) ou secondaire (liseré).
struct BannerButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        BannerButton(configuration: configuration, prominent: prominent)
    }
}

extension ButtonStyle where Self == BannerButtonStyle {
    static var bannerPrimary: BannerButtonStyle { .init(prominent: true) }
    static var bannerSecondary: BannerButtonStyle { .init(prominent: false) }
}

private struct BannerButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.bannerTone) private var tone
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let live = tone == .live
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        configuration.label
            .font(.callout.weight(prominent ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 10).frame(minHeight: 22)
            .foregroundStyle(foreground(live: live))
            .background(fill(live: live), in: shape)
            .overlay(shape.strokeBorder(stroke(live: live)))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }

    /// Fond du bouton principal (texte blanc lisible) ; texte rouge sur blanc pour le ton `live`.
    private var accent: Color { tone.strongColor }

    private func foreground(live: Bool) -> Color {
        if prominent { return live ? accent : .white }
        return live ? .white : .primary
    }

    private func fill(live: Bool) -> Color {
        let pressed = configuration.isPressed
        if prominent {
            let base = live ? Color.white : accent
            return base.opacity(pressed ? 0.75 : hovering ? 0.9 : 1)
        }
        let base = live ? Color.white : Color.primary
        return base.opacity(pressed ? 0.22 : hovering ? 0.14 : (live ? 0.16 : 0.08))
    }

    private func stroke(live: Bool) -> Color {
        if prominent { return .clear }
        return live ? Color.white.opacity(0.55) : Color.primary.opacity(0.3)
    }
}
