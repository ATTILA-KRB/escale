import Foundation

// MARK: Erreurs

/// Erreurs du client RFB (messages en français, jamais de secret).
public enum RFBError: Error, Equatable, Sendable, CustomStringConvertible {
    case connectionClosed
    case transport(String)
    case unsupportedVersion(String)
    case protocolViolation(String)
    case unsupportedSecurity([UInt8])
    /// Le serveur refuse la connexion avant l'authentification (message du serveur).
    case refused(String)
    case authenticationFailed(String)
    case authenticationCancelled
    case timeout

    public var description: String {
        switch self {
        case .connectionClosed: "Connexion fermée par le serveur."
        case .transport(let m): m
        case .unsupportedVersion(let v): "Version de protocole non prise en charge : « \(v) »."
        case .protocolViolation(let m): "Erreur de protocole VNC : \(m)."
        case .unsupportedSecurity(let types):
            "Aucun type de sécurité commun (serveur : \(types.map(String.init).joined(separator: ", "))). "
                + "Escale gère « Aucune », « VNC » et « Apple Remote Desktop »."
        case .refused(let m): "Connexion refusée par le serveur : \(m)"
        case .authenticationFailed(let m): m
        case .authenticationCancelled: "Authentification annulée."
        case .timeout: "Le serveur ne répond pas (délai dépassé)."
        }
    }
}

/// Octets manquants pour finir de décoder un rectangle : `total` octets depuis le début du rectangle sont nécessaires
/// (au moins). Le client attend ce volume puis relance le décodage depuis le début du rectangle.
public struct RFBNeedMoreData: Error, Equatable, Sendable { public let total: Int }

// MARK: Géométrie et lecture

public struct RFBRect: Equatable, Hashable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// Lecteur d'octets big-endian sur un tampon. Une lecture trop longue lève `RFBNeedMoreData` (sans rien consommer
/// de définitif : le décodeur est relancé depuis le début du rectangle).
public struct RFBByteReader {
    public let bytes: [UInt8]
    public private(set) var position: Int
    private let origin: Int

    public init(_ bytes: [UInt8], position: Int = 0) { self.bytes = bytes; self.position = position; origin = position }

    /// Octets lus depuis le début.
    public var consumed: Int { position - origin }
    public var remaining: Int { bytes.count - position }

    public mutating func need(_ n: Int) throws {
        if bytes.count - position < n { throw RFBNeedMoreData(total: position - origin + n) }
    }

    public mutating func u8() throws -> UInt8 { try need(1); defer { position += 1 }; return bytes[position] }
    public mutating func u16() throws -> Int {
        try need(2); defer { position += 2 }
        return Int(bytes[position]) << 8 | Int(bytes[position + 1])
    }
    public mutating func u32() throws -> UInt32 {
        try need(4); defer { position += 4 }
        return UInt32(bytes[position]) << 24 | UInt32(bytes[position + 1]) << 16 | UInt32(bytes[position + 2]) << 8 | UInt32(bytes[position + 3])
    }
    public mutating func skip(_ n: Int) throws { try need(n); position += n }
    public mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        try need(n); defer { position += n }
        return bytes[position..<position + n]
    }
}

// MARK: Format de pixels

public struct RFBPixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8, depth: UInt8
    public var bigEndian: Bool, trueColor: Bool
    public var redMax: UInt16, greenMax: UInt16, blueMax: UInt16
    public var redShift: UInt8, greenShift: UInt8, blueShift: UInt8

    /// Format demandé au serveur : 32 bpp, profondeur 24, petit-boutiste, R=bits 16-23, G=8-15, B=0-7 :
    /// en mémoire les octets d'un pixel sont B, G, R, (inutilisé) = BGRA du framebuffer, et le CPIXEL de ZRLE fait 3 octets.
    public static let bgra32 = RFBPixelFormat(
        bitsPerPixel: 32, depth: 24, bigEndian: false, trueColor: true,
        redMax: 255, greenMax: 255, blueMax: 255, redShift: 16, greenShift: 8, blueShift: 0)

    public var wireBytes: [UInt8] {
        [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColor ? 1 : 0,
         UInt8(redMax >> 8), UInt8(redMax & 0xff), UInt8(greenMax >> 8), UInt8(greenMax & 0xff),
         UInt8(blueMax >> 8), UInt8(blueMax & 0xff), redShift, greenShift, blueShift, 0, 0, 0]
    }
}

// MARK: Tampon de pixels

/// Accès aux pixels BGRA (4 octets par pixel, ligne par ligne) pendant le décodage d'un rectangle. Tout est vérifié
/// contre les bornes : un serveur hostile ne peut pas écrire hors du tampon.
public struct RFBPixelBuffer {
    public let width: Int
    public let height: Int
    let base: UnsafeMutablePointer<UInt8>

    init(width: Int, height: Int, base: UnsafeMutablePointer<UInt8>) { self.width = width; self.height = height; self.base = base }

    public func contains(_ r: RFBRect) -> Bool {
        r.x >= 0 && r.y >= 0 && r.width >= 0 && r.height >= 0 && r.x + r.width <= width && r.y + r.height <= height
    }

    /// Remplit un rectangle d'une couleur unie.
    public func fill(_ r: RFBRect, b: UInt8, g: UInt8, r red: UInt8) {
        guard contains(r), !r.isEmpty else { return }
        for row in r.y..<r.y + r.height {
            var p = base + (row * width + r.x) * 4
            for _ in 0..<r.width { p[0] = b; p[1] = g; p[2] = red; p[3] = 255; p += 4 }
        }
    }

    public func setPixel(x: Int, y: Int, b: UInt8, g: UInt8, r red: UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let p = base + (y * width + x) * 4
        p[0] = b; p[1] = g; p[2] = red; p[3] = 255
    }

    public func pixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        let p = base + (y * width + x) * 4
        return (p[0], p[1], p[2])
    }

    /// Copie une ligne de `count` pixels BGRX (4 octets) pris dans `src` à partir de `offset`.
    func writeRow(x: Int, y: Int, count: Int, from src: [UInt8], offset: Int) {
        let p = base + (y * width + x) * 4
        src.withUnsafeBufferPointer { sp in
            for i in 0..<count {
                let s = offset + i * 4
                p[i * 4] = sp[s]; p[i * 4 + 1] = sp[s + 1]; p[i * 4 + 2] = sp[s + 2]; p[i * 4 + 3] = 255
            }
        }
    }
}

// MARK: Framebuffer

/// Tampon d'écran distant, BGRA. Écrit par le client RFB (décodeurs), lu par l'interface (`snapshot`) : verrou interne.
public final class RFBFramebuffer: @unchecked Sendable {
    /// Plafond de pixels (taille de bureau hostile) : 16384 × 8192.
    public static let maxPixels = 16384 * 8192

    private struct State { var width: Int; var height: Int; var pixels: [UInt8] }
    private let lock = NSLock()
    private var state: State

    public init(width: Int = 0, height: Int = 0) {
        precondition(width >= 0 && height >= 0)
        state = State(width: width, height: height, pixels: Self.blank(width, height))
    }

    private static func blank(_ w: Int, _ h: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: w * h * 4)
        var i = 3; while i < p.count { p[i] = 255; i += 4 }
        return p
    }

    private func locked<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&state)
    }

    public var width: Int { locked { $0.width } }
    public var height: Int { locked { $0.height } }

    /// Nouvelle taille (contenu noir). Refuse une taille nulle ou démesurée.
    public func resize(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 65535, height <= 65535, width * height <= Self.maxPixels else {
            throw RFBError.protocolViolation("taille d'écran invalide (\(width)×\(height))")
        }
        locked { $0 = State(width: width, height: height, pixels: Self.blank(width, height)) }
    }

    /// Accès exclusif aux pixels le temps du bloc (décodage d'un rectangle).
    public func withPixels<T>(_ body: (RFBPixelBuffer) throws -> T) rethrows -> T {
        try locked { s in
            let w = s.width, h = s.height
            return try s.pixels.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else {
                    var dummy: UInt8 = 0
                    return try withUnsafeMutablePointer(to: &dummy) { try body(RFBPixelBuffer(width: 0, height: 0, base: $0)) }
                }
                return try body(RFBPixelBuffer(width: w, height: h, base: base))
            }
        }
    }

    /// Copie des pixels (BGRA, 4 octets par pixel) et dimensions : pour fabriquer une image côté interface.
    public func snapshot() -> (width: Int, height: Int, bgra: [UInt8]) {
        locked { ($0.width, $0.height, $0.pixels) }
    }

    /// Pixel (b, g, r) ; nil hors du tampon (tests).
    public func pixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8)? {
        locked { s in
            guard x >= 0, y >= 0, x < s.width, y < s.height else { return nil }
            let i = (y * s.width + x) * 4
            return (s.pixels[i], s.pixels[i + 1], s.pixels[i + 2])
        }
    }
}
