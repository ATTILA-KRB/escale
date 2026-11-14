import SwiftUI
import AppKit

/// Instantané transmis par SwiftUI (sert à relancer la mise en page quand l'arbre, le panneau actif
/// ou la présence d'un bandeau changent ; la géométrie est relue en direct sur les modèles).
struct PaneHostTab {
    let tab: TerminalTab
    let layout: PaneLayout
    let bannerIDs: Set<UUID>
    /// Panneaux dont la barre de monitoring distant est affichée (module Monitoring).
    var monitorIDs: Set<UUID> = []
}

/// Héberge TOUTES les vues de moteur (une par panneau de chaque onglet) : scinder, fermer ou changer d'onglet
/// ne fait que déplacer/masquer des vues, un moteur (écran, scrollback) n'est jamais recréé.
/// La zone du moteur est un multiple entier de la hauteur de cellule ; le bandeau est une barre séparée.
struct PaneHost: NSViewRepresentable {
    let model: AppModel
    let tabs: [PaneHostTab]
    let activeID: UUID?

    func makeNSView(context: Context) -> PaneHostView { PaneHostView(model: model) }

    func updateNSView(_ view: PaneHostView, context: Context) { view.sync(tabs: tabs, activeID: activeID) }
}

@MainActor
final class PaneHostView: NSView {
    /// Marges autour de la grille : le texte ne colle pas aux bords ; le fond noir remplit la marge.
    static let insetX: CGFloat = 8
    static let insetTop: CGFloat = 6
    static let insetBottom: CGFloat = 4

    private let model: AppModel
    private var tabs: [PaneHostTab] = []
    private var activeTabID: UUID?
    private var lastFocus: (UUID?, UUID?) = (nil, nil)
    private var engines: [UUID: SwiftTermEngine] = [:]
    private var banners: [UUID: NSHostingView<PaneBanner>] = [:]
    private var chromes: [UUID: PaneChromeView] = [:]
    private var monitorBars: [UUID: NSHostingView<MonitoringBar>] = [:]
    private var dividers: [UUID: PaneDividerView] = [:]
    private var clickMonitor: Any?

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override var isFlipped: Bool { true }

    // MARK: Synchronisation

    func sync(tabs list: [PaneHostTab], activeID: UUID?) {
        tabs = list
        activeTabID = activeID
        let alive = Set(list.flatMap { $0.tab.panes.map(\.id) })
        let aliveSplits = Set(list.flatMap { $0.layout.splitIDs })
        for (id, e) in engines where !alive.contains(id) { e.view.removeFromSuperview(); engines[id] = nil }
        for (id, v) in banners where !alive.contains(id) || !list.contains(where: { $0.bannerIDs.contains(id) }) {
            v.removeFromSuperview(); banners[id] = nil
        }
        for (id, v) in monitorBars where !alive.contains(id) || !list.contains(where: { $0.monitorIDs.contains(id) }) {
            v.removeFromSuperview(); monitorBars[id] = nil
        }
        for (id, v) in chromes where !alive.contains(id) { v.removeFromSuperview(); chromes[id] = nil }
        for (id, v) in dividers where !aliveSplits.contains(id) { v.removeFromSuperview(); dividers[id] = nil }
        for t in list {
            for p in t.tab.panes {
                let e = p.session.engine
                if engines[p.id] == nil {
                    e.view.autoresizingMask = []
                    addSubview(e.view)
                    engines[p.id] = e
                    let c = PaneChromeView()
                    addSubview(c)
                    chromes[p.id] = c
                }
                if t.monitorIDs.contains(p.id), monitorBars[p.id] == nil, let m = model.monitoring.monitor(for: p.id) {
                    let b = NSHostingView(rootView: MonitoringBar(feature: model.monitoring, monitor: m, hostName: p.baseTitle))
                    b.sizingOptions = []
                    addSubview(b)
                    monitorBars[p.id] = b
                }
                if t.bannerIDs.contains(p.id), banners[p.id] == nil {
                    let b = NSHostingView(rootView: PaneBanner(model: model, pane: p))
                    b.sizingOptions = []
                    addSubview(b)
                    banners[p.id] = b
                }
            }
            for id in t.layout.splitIDs where dividers[id] == nil {
                let d = PaneDividerView(splitID: id)
                d.host = self
                addSubview(d)
                dividers[id] = d
            }
        }
        needsLayout = true
        let focus = (activeID, list.first { $0.tab.id == activeID }?.layout.active)
        if focus != lastFocus { lastFocus = focus; focusActive() }
    }

    private func focusActive() {
        // Après la fin du cycle de mise en place (la vue peut venir d'être insérée).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let t = self.tabs.first(where: { $0.tab.id == self.activeTabID }),
                      let e = self.engines[t.tab.layout.active] else { return }
                e.focus()
                for t in self.tabs where t.tab.id == self.activeTabID { for p in t.tab.panes { self.engines[p.id]?.refreshDisplay() } }
            }
        }
    }

    // MARK: Mise en page

    /// Rectangle de la grille d'un panneau (multiple entier de la hauteur de cellule), dans notre repère.
    private func engineRect(pane rect: CGRect, hasBanner: Bool, hasMonitor: Bool = false, cellHeight: CGFloat) -> CGRect {
        var area = rect
        if hasBanner { let bh = PaneBanner.height(forWidth: rect.width); area.origin.y += bh; area.size.height -= bh }
        if hasMonitor { area.size.height -= MonitoringBar.height }
        let w = max(area.width - 2 * Self.insetX, 1)
        let avail = max(area.height - Self.insetTop - Self.insetBottom, 1)
        let h = cellHeight > 0 ? max(floor(avail / cellHeight), 1) * cellHeight : avail
        return CGRect(x: area.minX + Self.insetX, y: area.minY + Self.insetTop, width: w, height: h)
    }

    override func layout() {
        super.layout()
        for t in tabs {
            let visible = t.tab.id == activeTabID
            t.tab.viewSize = bounds.size
            let live = t.tab.layout
            let g = live.geometry(in: bounds)
            let multi = live.count > 1
            for p in t.tab.panes {
                guard let rect = g.panes[p.id], let e = engines[p.id] else { continue }
                let hasBanner = banners[p.id] != nil && t.bannerIDs.contains(p.id)
                if let b = banners[p.id] {
                    b.isHidden = !visible || !hasBanner
                    b.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: PaneBanner.height(forWidth: rect.width))
                }
                let hasMonitor = monitorBars[p.id] != nil && t.monitorIDs.contains(p.id)
                if let m = monitorBars[p.id] {
                    m.isHidden = !visible || !hasMonitor
                    m.frame = CGRect(x: rect.minX, y: rect.maxY - MonitoringBar.height, width: rect.width, height: MonitoringBar.height)
                }
                let er = engineRect(pane: rect, hasBanner: hasBanner, hasMonitor: hasMonitor, cellHeight: e.cellHeight)
                e.view.isHidden = !visible
                if e.view.frame != er { e.view.frame = er }
                if let c = chromes[p.id] {
                    var area = rect
                    if hasBanner { let bh = PaneBanner.height(forWidth: rect.width); area.origin.y += bh; area.size.height -= bh }
                    c.frame = area
                    c.isHidden = !visible || !multi
                    c.isActive = p.id == live.active
                }
            }
            for d in g.dividers {
                guard let v = dividers[d.splitID] else { continue }
                v.isHidden = !visible
                v.apply(d)
            }
        }
    }

    // MARK: Interaction

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if window != nil {
            // Clic dans un panneau = panneau actif + focus clavier (le clic continue vers le terminal).
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.window { self.activatePane(atWindowPoint: event.locationInWindow) }
                }
                return event
            }
            focusActive()
        }
    }
    deinit { MainActor.assumeIsolated { if let m = clickMonitor { NSEvent.removeMonitor(m) } } }

    /// Active le panneau situé sous un point (coordonnées fenêtre) ; vrai si un panneau a été trouvé.
    @discardableResult
    func activatePane(atWindowPoint wp: NSPoint) -> Bool {
        let p = convert(wp, from: nil)
        guard bounds.contains(p), let t = tabs.first(where: { $0.tab.id == activeTabID }) else { return false }
        let g = t.tab.layout.geometry(in: bounds)
        guard let (id, _) = g.panes.first(where: { $0.value.contains(p) }) else { return false }
        t.tab.setActive(id)
        engines[id]?.focus()
        return true
    }

    /// Glissement d'un séparateur : `point` dans notre repère.
    func dragDivider(_ splitID: UUID, to point: NSPoint) {
        guard let t = tabs.first(where: { $0.tab.id == activeTabID }),
              let d = t.tab.layout.geometry(in: bounds).dividers.first(where: { $0.splitID == splitID }) else { return }
        let th = PaneLayout.dividerThickness
        let ratio: Double = d.axis == .horizontal
            ? (point.x - d.parentRect.minX - th / 2) / max(d.parentRect.width - th, 1)
            : (point.y - d.parentRect.minY - th / 2) / max(d.parentRect.height - th, 1)
        t.tab.setRatio(splitID, ratio)
        needsLayout = true
    }

    func equalizeActiveTab() {
        tabs.first(where: { $0.tab.id == activeTabID })?.tab.equalize()
        needsLayout = true
    }

    // MARK: Accès pour l'auto-test
    func dividerView(_ splitID: UUID) -> PaneDividerView? { dividers[splitID] }
    func monitorBarView(_ paneID: UUID) -> NSView? { monitorBars[paneID].flatMap { $0.isHidden ? nil : $0 } }
    func bannerView(_ paneID: UUID) -> NSView? { banners[paneID].flatMap { $0.isHidden ? nil : $0 } }
    func chromeView(_ paneID: UUID) -> PaneChromeView? { chromes[paneID] }
}

/// Liseré sobre sur le panneau actif (onglet à plusieurs panneaux) ; les inactifs sont légèrement atténués.
/// Transparent aux clics.
@MainActor
final class PaneChromeView: NSView {
    var isActive = false { didSet { if oldValue != isActive { refresh() } } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    private func refresh() {
        guard let l = layer else { return }
        if isActive {
            l.backgroundColor = NSColor.clear.cgColor
            l.borderWidth = 1
            l.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        } else {
            l.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
            l.borderWidth = 0
        }
    }
    var describesActive: Bool { layer?.borderWidth == 1 }
}

/// Séparateur fin déplaçable (curseur de redimensionnement ; double-clic = égaliser).
@MainActor
final class PaneDividerView: NSView {
    let splitID: UUID
    weak var host: PaneHostView?
    private(set) var divider: PaneDivider?
    private var hovering = false { didSet { needsDisplay = true } }

    init(splitID: UUID) {
        self.splitID = splitID
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func apply(_ d: PaneDivider) {
        if divider != d { divider = d; needsDisplay = true; window?.invalidateCursorRects(for: self) }
        if frame != d.rect { frame = d.rect }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: divider?.axis == .vertical ? .resizeUpDown : .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        (hovering ? NSColor.controlAccentColor : NSColor(white: 0.32, alpha: 1)).setFill()
        let line: NSRect = divider?.axis == .vertical
            ? NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
            : NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
        line.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { host?.equalizeActiveTab() } else { drag(event) }
    }
    override func mouseDragged(with event: NSEvent) { drag(event) }
    private func drag(_ event: NSEvent) {
        guard let host else { return }
        host.dragDivider(splitID, to: host.convert(event.locationInWindow, from: nil))
    }
}
