import Foundation

/// Sens d'une scission : `horizontal` = panneaux côte à côte, `vertical` = panneaux empilés.
enum PaneAxis: Equatable, Sendable { case horizontal, vertical }

enum PaneDirection: Equatable, Sendable { case left, right, up, down }

/// Arbre de panneaux : feuille = identifiant de panneau ; nœud = scission (premier = gauche ou haut).
indirect enum PaneNode: Equatable, Sendable {
    case leaf(UUID)
    case split(id: UUID, axis: PaneAxis, ratio: Double, first: PaneNode, second: PaneNode)

    var leafIDs: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, _, let f, let s): f.leafIDs + s.leafIDs
        }
    }
}

/// Séparateur calculé : sa géométrie et le rectangle de la scission qu'il règle.
struct PaneDivider: Equatable, Sendable {
    let splitID: UUID
    let axis: PaneAxis
    let rect: CGRect
    let parentRect: CGRect
}

/// Disposition d'un onglet : arbre + panneau actif. Opérations pures (aucune vue, aucun moteur).
/// Géométrie en coordonnées « origine en haut à gauche » (y croît vers le bas).
struct PaneLayout: Equatable, Sendable {
    static let dividerThickness: CGFloat = 6
    static let minPaneSize = CGSize(width: 120, height: 64)

    private(set) var root: PaneNode
    var active: UUID

    init(first: UUID) { root = .leaf(first); active = first }

    var leafIDs: [UUID] { root.leafIDs }
    var count: Int { root.leafIDs.count }
    func contains(_ id: UUID) -> Bool { leafIDs.contains(id) }

    // MARK: Scission et fermeture

    /// Remplace la feuille `id` par une scission (`id` d'abord, `newID` ensuite) ; le nouveau panneau devient actif.
    @discardableResult
    mutating func split(_ id: UUID, axis: PaneAxis, newID: UUID, ratio: Double = 0.5) -> Bool {
        guard contains(id) else { return false }
        func go(_ n: PaneNode) -> PaneNode {
            switch n {
            case .leaf(let x):
                return x == id ? .split(id: UUID(), axis: axis, ratio: ratio, first: n, second: .leaf(newID)) : n
            case .split(let sid, let a, let r, let f, let s):
                return .split(id: sid, axis: a, ratio: r, first: go(f), second: go(s))
            }
        }
        root = go(root)
        active = newID
        return true
    }

    /// Retire `id` : le frère reprend la place. Faux (et rien ne change) si c'est le dernier panneau.
    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        guard contains(id), count > 1 else { return false }
        var siblingFirstLeaf: UUID?
        func go(_ n: PaneNode) -> PaneNode? {
            switch n {
            case .leaf(let x): return x == id ? nil : n
            case .split(let sid, let a, let r, let f, let s):
                let nf = go(f), ns = go(s)
                if nf == nil { siblingFirstLeaf = ns?.leafIDs.first; return ns }
                if ns == nil { siblingFirstLeaf = nf?.leafIDs.first; return nf }
                return .split(id: sid, axis: a, ratio: r, first: nf!, second: ns!)
            }
        }
        guard let newRoot = go(root) else { return false }
        root = newRoot
        if active == id { active = siblingFirstLeaf ?? newRoot.leafIDs[0] }
        return true
    }

    // MARK: Focus

    mutating func focusNext() { step(1) }
    mutating func focusPrevious() { step(-1) }
    private mutating func step(_ d: Int) {
        let ids = leafIDs
        guard let i = ids.firstIndex(of: active) else { return }
        active = ids[(i + d + ids.count) % ids.count]
    }

    /// Voisin géométrique dans une direction (le plus proche, à recouvrement non nul) ; nil s'il n'y en a pas.
    func neighbor(of id: UUID, _ dir: PaneDirection, in rect: CGRect) -> UUID? {
        let g = geometry(in: rect).panes
        guard let c = g[id] else { return nil }
        var best: (UUID, CGFloat, CGFloat)?
        for leaf in leafIDs where leaf != id {
            guard let r = g[leaf] else { continue }
            let gap: CGFloat, overlap: CGFloat
            switch dir {
            case .right: gap = r.minX - c.maxX; overlap = min(r.maxY, c.maxY) - max(r.minY, c.minY)
            case .left: gap = c.minX - r.maxX; overlap = min(r.maxY, c.maxY) - max(r.minY, c.minY)
            case .down: gap = r.minY - c.maxY; overlap = min(r.maxX, c.maxX) - max(r.minX, c.minX)
            case .up: gap = c.minY - r.maxY; overlap = min(r.maxX, c.maxX) - max(r.minX, c.minX)
            }
            guard gap >= -1, overlap > 1 else { continue }
            if let b = best, (gap, -overlap) >= (b.1, -b.2) { continue }
            best = (leaf, gap, overlap)
        }
        return best?.0
    }

    @discardableResult
    mutating func focus(_ dir: PaneDirection, in rect: CGRect) -> Bool {
        guard let n = neighbor(of: active, dir, in: rect) else { return false }
        active = n
        return true
    }

    // MARK: Proportions

    /// Fixe la proportion de la scission `splitID` (bornée : aucun côté sous la taille minimale).
    @discardableResult
    mutating func setRatio(_ splitID: UUID, _ ratio: Double, in rect: CGRect) -> Bool {
        guard let d = geometry(in: rect).dividers.first(where: { $0.splitID == splitID }) else { return false }
        func go(_ n: PaneNode) -> PaneNode {
            switch n {
            case .leaf: return n
            case .split(let sid, let a, let r, let f, let s):
                if sid == splitID {
                    let total = (a == .horizontal ? d.parentRect.width : d.parentRect.height) - Self.dividerThickness
                    return .split(id: sid, axis: a, ratio: Self.clamp(ratio, total: total, axis: a, first: f, second: s), first: f, second: s)
                }
                return .split(id: sid, axis: a, ratio: r, first: go(f), second: go(s))
            }
        }
        root = go(root)
        return true
    }

    /// Égalise : à chaque scission, proportion = part (en nombre de panneaux alignés sur l'axe) du premier côté.
    mutating func equalize() {
        func go(_ n: PaneNode) -> PaneNode {
            switch n {
            case .leaf: return n
            case .split(let sid, let a, _, let f, let s):
                let sf = Double(Self.spans(f, a)), ss = Double(Self.spans(s, a))
                return .split(id: sid, axis: a, ratio: sf / (sf + ss), first: go(f), second: go(s))
            }
        }
        root = go(root)
    }

    /// Proportion effective de chaque scission (testes : après égalisation, 0,5 pour deux panneaux).
    var ratios: [Double] {
        var out: [Double] = []
        func go(_ n: PaneNode) {
            if case .split(_, _, let r, let f, let s) = n { out.append(r); go(f); go(s) }
        }
        go(root)
        return out
    }
    var splitIDs: [UUID] {
        var out: [UUID] = []
        func go(_ n: PaneNode) {
            if case .split(let id, _, _, let f, let s) = n { out.append(id); go(f); go(s) }
        }
        go(root)
        return out
    }

    private static func spans(_ n: PaneNode, _ axis: PaneAxis) -> Int {
        switch n {
        case .leaf: 1
        case .split(_, let a, _, let f, let s):
            a == axis ? spans(f, axis) + spans(s, axis) : max(spans(f, axis), spans(s, axis))
        }
    }

    private static func minLength(_ n: PaneNode, _ axis: PaneAxis) -> CGFloat {
        let k = CGFloat(spans(n, axis))
        let side = axis == .horizontal ? minPaneSize.width : minPaneSize.height
        return k * side + (k - 1) * dividerThickness
    }

    private static func clamp(_ ratio: Double, total: CGFloat, axis: PaneAxis, first: PaneNode, second: PaneNode) -> Double {
        guard total > 0 else { return 0.5 }
        let lo = minLength(first, axis), hi = total - minLength(second, axis)
        if hi < lo { return 0.5 } // trop petit pour respecter les minimums : moitié-moitié
        let len = min(max(CGFloat(ratio) * total, lo), hi)
        return Double(len / total)
    }

    // MARK: Géométrie

    func geometry(in rect: CGRect) -> (panes: [UUID: CGRect], dividers: [PaneDivider]) {
        var panes: [UUID: CGRect] = [:]
        var dividers: [PaneDivider] = []
        let d = Self.dividerThickness
        func walk(_ n: PaneNode, _ r: CGRect) {
            switch n {
            case .leaf(let id): panes[id] = r
            case .split(let sid, let axis, let ratio, let f, let s):
                let total = (axis == .horizontal ? r.width : r.height) - d
                let eff = Self.clamp(ratio, total: total, axis: axis, first: f, second: s)
                let len = (max(total, 0) * eff).rounded()
                if axis == .horizontal {
                    let a = CGRect(x: r.minX, y: r.minY, width: len, height: r.height)
                    let div = CGRect(x: a.maxX, y: r.minY, width: d, height: r.height)
                    let b = CGRect(x: div.maxX, y: r.minY, width: max(r.maxX - div.maxX, 0), height: r.height)
                    dividers.append(PaneDivider(splitID: sid, axis: axis, rect: div, parentRect: r))
                    walk(f, a); walk(s, b)
                } else {
                    let a = CGRect(x: r.minX, y: r.minY, width: r.width, height: len)
                    let div = CGRect(x: r.minX, y: a.maxY, width: r.width, height: d)
                    let b = CGRect(x: r.minX, y: div.maxY, width: r.width, height: max(r.maxY - div.maxY, 0))
                    dividers.append(PaneDivider(splitID: sid, axis: axis, rect: div, parentRect: r))
                    walk(f, a); walk(s, b)
                }
            }
        }
        walk(root, rect)
        return (panes, dividers)
    }
}
