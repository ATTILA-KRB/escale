import Foundation
import EscaleCore

/// Scénario `--selftest-rdp <dossier>` : écrit `<dossier>/result.json` (ok, checks, failed, details). PROVISOIRE.
@MainActor
final class RDPSelfTest {
    let directory: String
    let model: AppModel

    init(directory: String, model: AppModel) { self.directory = directory; self.model = model }

    func run() async -> Bool {
        let r: [String: Any] = ["ok": false, "checks": [String: Bool](), "failed": ["provisoire"], "details": [String: String]()]
        if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: directory).appendingPathComponent("result.json"))
        }
        return false
    }
}
