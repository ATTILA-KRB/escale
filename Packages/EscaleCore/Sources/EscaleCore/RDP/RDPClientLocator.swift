import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Détection du client Bureau à distance de Microsoft (« Windows App », ancien « Microsoft Remote Desktop »).
/// La recherche passe par une fonction injectable (tests : aucun client réel requis).
public struct RDPClientLocator: Sendable {
    /// Identifiant de bundle de « Windows App » (et de l'ancien « Microsoft Remote Desktop »).
    public static let bundleIdentifier = "com.microsoft.rdc.macos"
    /// Page de « Windows App » sur l'App Store.
    public static let appStoreURL = URL(string: "https://apps.apple.com/app/windows-app/id1295203466")!

    /// URLs des applications installées pour un identifiant de bundle.
    public var applicationURLs: @Sendable (String) -> [URL]

    public init(applicationURLs: @escaping @Sendable (String) -> [URL] = RDPClientLocator.systemApplicationURLs) {
        self.applicationURLs = applicationURLs
    }

    /// Premier client installé (ordre de Launch Services), nil s'il n'y en a pas.
    public func locate() -> URL? { applicationURLs(Self.bundleIdentifier).first }

    /// Recherche réelle (Launch Services).
    @Sendable public static func systemApplicationURLs(_ bundleID: String) -> [URL] {
        #if canImport(AppKit)
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        #else
        return []
        #endif
    }
}
