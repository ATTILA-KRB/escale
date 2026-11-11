import Foundation
import Darwin

/// Aides pour l'option « Ouvrir via un hôte SSH » : la connexion Telnet passe par un tunnel `-L` local ouvert sur le maître.
public enum TelnetTunnel {
    /// Redirection locale 127.0.0.1:<port libre> → hôte:port Telnet, sur le maître de l'hôte SSH intermédiaire.
    public static func spec(localPort: Int, host: String, port: Int) -> TunnelSpec {
        // Adresse IPv6 littérale éventuellement notée entre crochets dans la bibliothèque.
        let dest = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return TunnelSpec(kind: .local, bindAddress: "127.0.0.1", bindPort: localPort,
                          destinationHost: dest, destinationPort: port, name: "Telnet")
    }

    /// Port TCP local libre (bind sur 0). Nil si le système refuse.
    public static func freeLocalPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        a.sin_port = 0
        let bound = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: a.sin_port))
    }
}
