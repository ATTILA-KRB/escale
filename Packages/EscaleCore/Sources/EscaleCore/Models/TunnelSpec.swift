import Foundation

/// Un tunnel SSH. `specArgument` est la valeur passée à `-L`, `-R` ou `-D`.
public struct TunnelSpec: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case local, remote, dynamic

        public var flag: String {
            switch self {
            case .local: "-L"
            case .remote: "-R"
            case .dynamic: "-D"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var bindAddress: String
    public var bindPort: Int
    /// Ignorés pour `.dynamic`.
    public var destinationHost: String
    public var destinationPort: Int

    public init(
        id: UUID = UUID(), kind: Kind, bindAddress: String = "127.0.0.1", bindPort: Int,
        destinationHost: String = "", destinationPort: Int = 0
    ) {
        self.id = id; self.kind = kind; self.bindAddress = bindAddress; self.bindPort = bindPort
        self.destinationHost = destinationHost; self.destinationPort = destinationPort
    }

    public var specArgument: String {
        switch kind {
        case .dynamic: "\(bindAddress):\(bindPort)"
        case .local, .remote: "\(bindAddress):\(bindPort):\(destinationHost):\(destinationPort)"
        }
    }
}
