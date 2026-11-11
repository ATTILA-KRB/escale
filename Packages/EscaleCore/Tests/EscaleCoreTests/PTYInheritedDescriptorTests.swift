import Testing
import Foundation
import Darwin
@testable import EscaleCore

extension PTYProcessTests {
    /// Course : des fd (sans CLOEXEC) sont ouverts et fermés en continu par un autre thread pendant que l'on lance des fils.
    /// Aucun ne doit survivre dans le fils (l'inventaire des fd se fait dans le fils, après le fork).
    @Test func descripteursOuvertsParUnAutreThreadNeFuientPas() async throws {
        let stop = Box(false)
        let churn = Thread {
            var held: [Int32] = []
            while !stop.value {
                for _ in 0..<8 {
                    let f = Darwin.open("/dev/null", O_RDONLY)
                    if f >= 0 { let g = fcntl(f, F_DUPFD, 20); Darwin.close(f); if g >= 0 { held.append(g) } }
                }
                for g in held { Darwin.close(g) }
                held.removeAll()
            }
        }
        churn.start()
        defer { stop.value = true }
        var leaked: [[Int]] = []
        for _ in 0..<60 {
            let p = try PTYProcess(executable: "/bin/ls", arguments: ["/dev/fd"], environment: ["PATH": "/usr/bin:/bin"], columns: 80, rows: 24)
            var out = Data()
            for await d in p.output { out.append(d) }
            _ = await p.waitForExit()
            let fds = String(decoding: out, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            if fds.contains(where: { $0 >= 10 }) { leaked.append(fds) }
        }
        #expect(leaked.isEmpty, "fd hérités par le fils : \(leaked.prefix(3))")
    }
}
