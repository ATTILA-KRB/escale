import AppKit
import SwiftTerm

/// Sous-classe de la `TerminalView` SwiftTerm : saisie composée (IME, touches mortes) et accessibilité.
/// Reste dans `Escale/Terminal/` (invariant 1).
///
/// ## Saisie composée
/// SwiftTerm 1.99 gère `setMarkedText`/`insertText`, mais :
/// - `insertText` ignore un `NSAttributedString` (certains IME CJK valident ainsi) : rien n'est envoyé ;
/// - `markedRange()` est relatif à 0 alors que `selectedRange()` est une position de cellule : l'IME reçoit des
///   intervalles incohérents et peut remplacer le mauvais texte ;
/// - `doCommand(by:)` (non surchargeable : `public override`, pas `open`) envoie Retour arrière, Échap, flèches…
///   pendant la composition, alors que ces touches appartiennent à l'IME. Le pont du moteur filtre donc toute
///   sortie produite pendant la composition (`shouldSuppressOutput`), sauf la validation du texte composé.
///
/// ## Accessibilité
/// La vue SwiftTerm macOS n'en a aucune (rôle AXUnknown). On expose un rôle AXTextArea dont la valeur est le texte
/// de l'écran + au plus `historyRows` lignes de scrollback (jamais tout le scrollback : un instantané complet de
/// 100 000 lignes coûte ~500 Mio). Le texte est reconstruit seulement quand VoiceOver le demande ET que le
/// contenu a changé ; les notifications `valueChanged` sont limitées à une par `notificationInterval`.
@MainActor
final class EscaleTerminalView: TerminalView {
    // MARK: Composition

    private var markedLength = 0
    private var markedSelection = NSRange(location: NSNotFound, length: 0)
    private var committing = false
    /// Vrai pendant que l'IME a un texte marqué en cours.
    private(set) var isComposing = false
    /// Nombre de sorties retenues pendant une composition (instrumentation de la recette).
    private(set) var suppressedOutputCount = 0

    /// Vrai si une sortie vers l'hôte doit être jetée : l'IME possède le clavier tant qu'il compose.
    var shouldSuppressOutput: Bool {
        guard isComposing && !committing else { return false }
        suppressedOutputCount += 1
        return true
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        syncCaretFrame()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        let length: Int
        switch string {
        case let a as NSAttributedString: length = a.length
        case let s as String: length = (s as NSString).length
        default: length = 0
        }
        markedLength = length
        markedSelection = selectedRange
        isComposing = length > 0
    }

    override func unmarkText() {
        super.unmarkText()
        markedLength = 0
        markedSelection = NSRange(location: NSNotFound, length: 0)
        isComposing = false
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Un IME peut valider avec un NSAttributedString : SwiftTerm ne gère que String/NSString.
        let plain: Any
        if let attributed = string as? NSAttributedString { plain = attributed.string } else { plain = string }
        committing = true
        super.insertText(plain, replacementRange: replacementRange)
        committing = false
        markedLength = 0
        markedSelection = NSRange(location: NSNotFound, length: 0)
        isComposing = false
    }

    /// Position du curseur dans l'espace de caractères que voit l'IME : même origine que `selectedRange()`.
    private var caretIndex: Int { super.selectedRange().location }

    override func markedRange() -> NSRange {
        guard isComposing else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: caretIndex, length: markedLength)
    }

    override func selectedRange() -> NSRange {
        guard isComposing, markedSelection.location != NSNotFound else { return super.selectedRange() }
        return NSRange(location: caretIndex + markedSelection.location, length: markedSelection.length)
    }

    override func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard isComposing, range.location != NSNotFound else { return super.attributedSubstring(forProposedRange: range, actualRange: actualRange) }
        // Les intervalles demandés sont dans l'espace de `markedRange()` ; SwiftTerm attend un décalage relatif.
        let rel = NSRange(location: max(0, range.location - caretIndex), length: range.length)
        return super.attributedSubstring(forProposedRange: rel, actualRange: actualRange)
    }

    /// Cellule du curseur dans le repère de la vue (grille ancrée en haut, repère AppKit non retourné).
    private func cursorCellRect() -> NSRect? {
        let dims = terminalDimensions
        guard dims.cols > 0, dims.rows > 0 else { return nil }
        let optimal = getOptimalFrameSize()
        let cellH = optimal.height / CGFloat(dims.rows)
        let cellW = optimal.width / CGFloat(dims.cols)
        var row = 0, col = 0
        if let snap = terminalContentSnapshot(region: .viewport) {
            row = max(0, min(dims.rows - 1, snap.cursorRow - snap.capturedRange.lowerBound))
            col = max(0, min(dims.cols - 1, snap.cursorColumn))
        }
        return NSRect(x: CGFloat(col) * cellW, y: bounds.height - CGFloat(row + 1) * cellH, width: cellW, height: cellH)
    }

    /// Avec le rendu Metal, la vue interne du curseur (`CaretView`) n'est jamais positionnée : elle reste à l'origine.
    /// SwiftTerm s'en sert pour dessiner le texte marqué (surcouche de composition) et pour `firstRect` : mesuré, la
    /// composition apparaissait dans le coin bas-gauche, loin du curseur. On la recale avant chaque composition.
    private func syncCaretFrame() {
        guard let rect = cursorCellRect(),
              let caret = subviews.first(where: { String(describing: type(of: $0)) == "CaretView" }) else { return }
        caret.frame = rect
    }

    /// Rectangle (écran) du curseur : l'IME place son panneau de candidats sous ce rectangle.
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let window, let rect = cursorCellRect() else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    // MARK: Accessibilité

    static let historyRows = 200
    static let notificationInterval: TimeInterval = 0.5

    var terminalAccessibilityLabel = "Terminal"
    /// Notifications VoiceOver même sans VoiceOver actif (recette).
    var forceAccessibilityNotifications = false
    private(set) var accessibilityNotificationCount = 0
    /// Nombre de reconstructions du texte (recette : il ne doit pas suivre le nombre de frappes).
    private(set) var accessibilityRebuildCount = 0

    private struct Snapshot {
        var text: String
        var visible: NSRange
        var caret: Int
    }
    private var cache: Snapshot?
    private var contentVersion = 0
    private var cacheVersion = -1
    private var lastNotification = Date.distantPast
    private var notificationScheduled = false

    /// Appelé à chaque sortie de l'hôte : invalide le cache (O(1)) et programme une notification limitée en fréquence.
    func contentDidChange() {
        contentVersion &+= 1
        guard forceAccessibilityNotifications || NSWorkspace.shared.isVoiceOverEnabled else { return }
        let wait = Self.notificationInterval - Date().timeIntervalSince(lastNotification)
        if wait <= 0 { postValueChanged(); return }
        guard !notificationScheduled else { return }
        notificationScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            guard let self else { return }
            self.notificationScheduled = false
            self.postValueChanged()
        }
    }

    private func postValueChanged() {
        lastNotification = Date()
        accessibilityNotificationCount += 1
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func snapshot() -> Snapshot {
        if let cache, cacheVersion == contentVersion { return cache }
        accessibilityRebuildCount += 1
        let built = buildSnapshot()
        cache = built; cacheVersion = contentVersion
        return built
    }

    private func buildSnapshot() -> Snapshot {
        guard let snap = terminalContentSnapshot(region: .history(maximumScrollbackRows: Self.historyRows)) else {
            return Snapshot(text: "", visible: NSRange(location: 0, length: 0), caret: 0)
        }
        var text = ""
        var visibleStart = 0
        var caret = 0
        var length = 0 // longueur UTF-16 courante
        for (i, row) in snap.rows.enumerated() {
            if i > 0 && !row.isWrapped { text += "\n"; length += 1 }
            let absolute = snap.capturedRange.lowerBound + i
            if absolute == snap.liveTopRow { visibleStart = length }
            var line = row.text
            while line.hasSuffix(" ") { line.removeLast() }
            if absolute == snap.cursorRow {
                caret = length + min(snap.cursorColumn, (line as NSString).length)
            }
            text += line
            length += (line as NSString).length
        }
        // Lignes vides finales : inutiles à VoiceOver (l'écran vivant est en grande partie vide).
        while text.hasSuffix("\n") { text.removeLast() }
        let total = (text as NSString).length
        visibleStart = min(visibleStart, total)
        return Snapshot(text: text, visible: NSRange(location: visibleStart, length: total - visibleStart), caret: min(caret, total))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityRoleDescription() -> String? { "terminal" }
    override func accessibilityLabel() -> String? { terminalAccessibilityLabel }
    override func accessibilityValue() -> Any? { snapshot().text }
    override func accessibilityNumberOfCharacters() -> Int { (snapshot().text as NSString).length }
    override func accessibilityVisibleCharacterRange() -> NSRange { snapshot().visible }

    override func accessibilitySelectedText() -> String? { getSelection() ?? "" }

    override func accessibilitySelectedTextRange() -> NSRange {
        let s = snapshot()
        if let sel = getSelection(), !sel.isEmpty {
            let r = (s.text as NSString).range(of: sel, options: .backwards)
            if r.location != NSNotFound { return r }
        }
        return NSRange(location: s.caret, length: 0)
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let ns = snapshot().text as NSString
        guard range.location != NSNotFound, range.location <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: range.location, length: min(range.length, ns.length - range.location)))
    }

    override func accessibilityLine(for index: Int) -> Int {
        let ns = snapshot().text as NSString
        let end = min(max(index, 0), ns.length)
        return ns.substring(to: end).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        let ns = snapshot().text as NSString
        var current = 0, start = 0
        while current < line {
            let r = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            if r.location == NSNotFound { return NSRange(location: ns.length, length: 0) }
            start = r.upperBound; current += 1
        }
        let r = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
        return NSRange(location: start, length: (r.location == NSNotFound ? ns.length : r.location) - start)
    }
}
