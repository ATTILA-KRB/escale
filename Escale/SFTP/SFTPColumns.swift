import SwiftUI
import Observation

/// Présentation du navigateur SFTP selon la largeur du volet : liste compacte (nom + détail sur deux lignes) ou
/// vraies colonnes. Un changement de mode exige de dépasser le seuil de `hysteresis` points, pour que la liste ne
/// clignote pas quand la largeur oscille autour d'un seuil (redimensionnement, apparition d'un ascenseur).
enum SFTPColumnsMode: Int, Comparable, Sendable {
    /// Liste compacte historique.
    case compact
    /// Nom, Taille, Date.
    case columns
    /// Nom, Taille, Date, Droits.
    case columnsWithPermissions

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    static let columnsThreshold: CGFloat = 430
    static let permissionsThreshold: CGFloat = 540
    static let hysteresis: CGFloat = 24

    var showsColumns: Bool { self != .compact }
    var showsPermissions: Bool { self == .columnsWithPermissions }

    /// Mode suivant pour une largeur mesurée : on monte dès le seuil, on ne redescend qu'à `seuil - hysteresis`.
    func updated(forWidth w: CGFloat) -> SFTPColumnsMode {
        var m = self
        if m < .columnsWithPermissions, w >= Self.permissionsThreshold { m = .columnsWithPermissions }
        if m < .columns, w >= Self.columnsThreshold { m = .columns }
        if m == .columnsWithPermissions, w < Self.permissionsThreshold - Self.hysteresis { m = .columns }
        if m == .columns, w < Self.columnsThreshold - Self.hysteresis { m = .compact }
        return m
    }
}

/// État de présentation partagé (largeur mesurée, mode retenu). Une seule liste est affichée à la fois ; la recette
/// lit `mode` pour vérifier le comportement sans deviner l'affichage.
@MainActor @Observable
final class SFTPColumnsState {
    static let shared = SFTPColumnsState()
    private(set) var width: CGFloat = 0
    private(set) var mode: SFTPColumnsMode = .compact

    func measured(_ w: CGFloat) {
        width = w
        let m = mode.updated(forWidth: w)
        if m != mode { mode = m }
    }
}

/// Largeurs fixes des colonnes (le nom prend le reste).
enum SFTPColumnMetrics {
    static let icon: CGFloat = 18
    /// 12 pt : à 8, la taille (alignée à droite) se collait à la date (alignée à gauche).
    static let spacing: CGFloat = 12
    static let size: CGFloat = 66
    static let date: CGFloat = 112
    static let permissions: CGFloat = 76
}

/// En-têtes des colonnes : un clic trie (même `SFTPSort.toggle` que la liste compacte), un second inverse l'ordre.
struct SFTPColumnsHeader: View {
    @Binding var sort: SFTPSort
    let mode: SFTPColumnsMode

    var body: some View {
        HStack(spacing: SFTPColumnMetrics.spacing) {
            Color.clear.frame(width: SFTPColumnMetrics.icon, height: 1)
            cell(.name).frame(maxWidth: .infinity, alignment: .leading)
            cell(.size).frame(width: SFTPColumnMetrics.size, alignment: .trailing)
            cell(.date).frame(width: SFTPColumnMetrics.date, alignment: .leading)
            if mode.showsPermissions {
                Text("Droits").font(.caption).frame(width: SFTPColumnMetrics.permissions, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 4)
        .foregroundStyle(.secondary)
    }

    private func cell(_ k: SFTPSortKey) -> some View {
        Button {
            var s = sort; s.toggle(k); sort = s
        } label: {
            HStack(spacing: 3) {
                Text(k.label)
                if sort.key == k {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }
            .font(.caption.weight(sort.key == k ? .bold : .regular))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sftp.column.\(k.rawValue)")
    }
}

/// Ligne en colonnes. Même icône et même nom que la ligne compacte ; le glisser-déposer, le menu et le double-clic
/// restent portés par la `List` et par `SFTPSessionView.row(_:)`.
struct SFTPColumnsRow: View {
    let item: SFTPItem
    let mode: SFTPColumnsMode

    var body: some View {
        HStack(spacing: SFTPColumnMetrics.spacing) {
            Image(systemName: item.isDirectory ? "folder.fill" : (item.isSymlink ? "link" : "doc"))
                .foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: SFTPColumnMetrics.icon)
            Text(item.name).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.isDirectory ? "" : SFTPFormat.size(item.size))
                .frame(width: SFTPColumnMetrics.size, alignment: .trailing).foregroundStyle(.secondary)
            Text(SFTPFormat.shortDate(item.modified))
                .frame(width: SFTPColumnMetrics.date, alignment: .leading).foregroundStyle(.secondary)
            if mode.showsPermissions {
                Text(item.permissionText).font(.system(.caption, design: .monospaced))
                    .frame(width: SFTPColumnMetrics.permissions, alignment: .leading).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .contentShape(Rectangle())
    }
}
