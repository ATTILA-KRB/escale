import Compression
import Foundation

/// Décodeurs d'encodages RFB (RFC 6143 §7.7), fonctions pures sur un lecteur d'octets et un tampon de pixels.
/// Format de pixel imposé par le client : `RFBPixelFormat.bgra32` (4 octets B, G, R, X ; CPIXEL de ZRLE : 3 octets B, G, R).
/// Un décodeur lève `RFBNeedMoreData` quand le rectangle n'est pas entièrement arrivé : il est alors relancé depuis le
/// début (les écritures sont idempotentes), sauf ZRLE dont le flux zlib n'est décompressé qu'une fois les octets complets.
public enum RFBEncoding {
    public static let raw: Int32 = 0
    public static let copyRect: Int32 = 1
    public static let rre: Int32 = 2
    public static let hextile: Int32 = 5
    public static let zrle: Int32 = 16
    // Pseudo-encodages
    public static let cursor: Int32 = -239
    public static let desktopSize: Int32 = -223

    /// Liste de SetEncodings selon la préférence (les pseudo-encodages suivent toujours).
    public static func list(for preference: VNCEncodingPreference) -> [Int32] {
        let real: [Int32]
        switch preference {
        case .auto: real = [zrle, hextile, rre, copyRect, raw]
        case .zrle: real = [zrle, copyRect, raw]
        case .hextile: real = [hextile, copyRect, raw]
        case .raw: real = [copyRect, raw]
        }
        return real + [cursor, desktopSize]
    }
}

public enum RFBDecoders {
    private static func violation(_ m: String) -> RFBError { .protocolViolation(m) }

    // MARK: Raw

    public static func decodeRaw(_ r: inout RFBByteReader, rect: RFBRect, into buf: RFBPixelBuffer) throws {
        guard buf.contains(rect) else { throw violation("rectangle Raw hors de l'écran") }
        let n = rect.width * rect.height * 4
        try r.need(n)
        let start = r.position
        for row in 0..<rect.height {
            buf.writeRow(x: rect.x, y: rect.y + row, count: rect.width, from: r.bytes, offset: start + row * rect.width * 4)
        }
        try r.skip(n)
    }

    // MARK: CopyRect

    public static func decodeCopyRect(_ r: inout RFBByteReader, rect: RFBRect, into buf: RFBPixelBuffer) throws {
        let sx = try r.u16(), sy = try r.u16()
        let src = RFBRect(x: sx, y: sy, width: rect.width, height: rect.height)
        guard buf.contains(rect), buf.contains(src) else { throw violation("CopyRect hors de l'écran") }
        // Copie via un tampon : source et destination peuvent se chevaucher.
        var tmp = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
        for row in 0..<rect.height {
            let s = buf.base + ((sy + row) * buf.width + sx) * 4
            for i in 0..<rect.width * 4 { tmp[row * rect.width * 4 + i] = s[i] }
        }
        for row in 0..<rect.height { buf.writeRow(x: rect.x, y: rect.y + row, count: rect.width, from: tmp, offset: row * rect.width * 4) }
    }

    // MARK: RRE

    public static func decodeRRE(_ r: inout RFBByteReader, rect: RFBRect, into buf: RFBPixelBuffer) throws {
        guard buf.contains(rect) else { throw violation("rectangle RRE hors de l'écran") }
        let count = Int(try r.u32())
        guard count <= rect.width * rect.height else { throw violation("RRE : trop de sous-rectangles") }
        try r.need(4 + count * 12)
        let bg = try r.take(4)
        buf.fill(rect, b: bg[bg.startIndex], g: bg[bg.startIndex + 1], r: bg[bg.startIndex + 2])
        for _ in 0..<count {
            let px = try r.take(4)
            let sub = RFBRect(x: rect.x + (try r.u16()), y: rect.y + (try r.u16()), width: try r.u16(), height: try r.u16())
            guard buf.contains(sub), sub.x + sub.width <= rect.x + rect.width, sub.y + sub.height <= rect.y + rect.height else {
                throw violation("sous-rectangle RRE hors du rectangle")
            }
            buf.fill(sub, b: px[px.startIndex], g: px[px.startIndex + 1], r: px[px.startIndex + 2])
        }
    }

    // MARK: Hextile

    public static func decodeHextile(_ r: inout RFBByteReader, rect: RFBRect, into buf: RFBPixelBuffer) throws {
        guard buf.contains(rect) else { throw violation("rectangle Hextile hors de l'écran") }
        var bg: (UInt8, UInt8, UInt8) = (0, 0, 0), fg: (UInt8, UInt8, UInt8) = (255, 255, 255)
        var ty = rect.y
        while ty < rect.y + rect.height {
            let th = min(16, rect.y + rect.height - ty)
            var tx = rect.x
            while tx < rect.x + rect.width {
                let tw = min(16, rect.x + rect.width - tx)
                let tile = RFBRect(x: tx, y: ty, width: tw, height: th)
                let sub = try r.u8()
                if sub & 1 != 0 { // Raw
                    try decodeRaw(&r, rect: tile, into: buf)
                } else {
                    if sub & 2 != 0 { let p = try r.take(4); bg = (p[p.startIndex], p[p.startIndex + 1], p[p.startIndex + 2]) }
                    if sub & 4 != 0 { let p = try r.take(4); fg = (p[p.startIndex], p[p.startIndex + 1], p[p.startIndex + 2]) }
                    buf.fill(tile, b: bg.0, g: bg.1, r: bg.2)
                    if sub & 8 != 0 {
                        let n = Int(try r.u8())
                        let coloured = sub & 16 != 0
                        for _ in 0..<n {
                            var c = fg
                            if coloured { let p = try r.take(4); c = (p[p.startIndex], p[p.startIndex + 1], p[p.startIndex + 2]) }
                            let xy = try r.u8(), wh = try r.u8()
                            let s = RFBRect(x: tx + Int(xy >> 4), y: ty + Int(xy & 15), width: Int(wh >> 4) + 1, height: Int(wh & 15) + 1)
                            guard s.x + s.width <= tx + tw, s.y + s.height <= ty + th else { throw violation("sous-rectangle Hextile hors de la tuile") }
                            buf.fill(s, b: c.0, g: c.1, r: c.2)
                        }
                    }
                }
                tx += 16
            }
            ty += 16
        }
    }

    // MARK: ZRLE

    /// Rectangle ZRLE : longueur (u32), données zlib (flux persistant pour toute la connexion), puis tuiles de 64×64.
    public static func decodeZRLE(_ r: inout RFBByteReader, rect: RFBRect, into buf: RFBPixelBuffer, inflater: RFBInflater) throws {
        guard buf.contains(rect) else { throw violation("rectangle ZRLE hors de l'écran") }
        let length = Int(try r.u32())
        guard length <= 64 << 20 else { throw violation("rectangle ZRLE trop gros") }
        let compressed = try r.take(length)
        // Borne de sortie : 64×64×3 par tuile au pire (+ palette/RLE), largement sous 4 octets par pixel + marge.
        let data = try inflater.inflate(Array(compressed), maxOutput: rect.width * rect.height * 4 + (rect.width / 64 + 2) * (rect.height / 64 + 2) * 4096 + 65536)
        try decodeZRLETiles(data, rect: rect, into: buf)
    }

    /// Tuiles ZRLE d'un tampon déjà décompressé (fonction pure, testée sur des rectangles synthétiques).
    public static func decodeZRLETiles(_ data: [UInt8], rect: RFBRect, into buf: RFBPixelBuffer) throws {
        guard buf.contains(rect) else { throw violation("rectangle ZRLE hors de l'écran") }
        var p = 0
        func byte() throws -> UInt8 {
            guard p < data.count else { throw violation("ZRLE tronqué") }
            defer { p += 1 }; return data[p]
        }
        func cpixel() throws -> (UInt8, UInt8, UInt8) {
            guard p + 3 <= data.count else { throw violation("ZRLE tronqué") }
            defer { p += 3 }; return (data[p], data[p + 1], data[p + 2])
        }
        func runLength() throws -> Int {
            var n = 1
            while true { let b = try byte(); n += Int(b); if b != 255 { break } }
            return n
        }
        var ty = rect.y
        while ty < rect.y + rect.height {
            let th = min(64, rect.y + rect.height - ty)
            var tx = rect.x
            while tx < rect.x + rect.width {
                let tw = min(64, rect.x + rect.width - tx)
                let sub = try byte()
                let rle = sub & 0x80 != 0
                let paletteSize = Int(sub & 0x7f)
                var palette: [(UInt8, UInt8, UInt8)] = []
                for _ in 0..<paletteSize { palette.append(try cpixel()) }
                let total = tw * th
                var written = 0
                func put(_ c: (UInt8, UInt8, UInt8), _ count: Int) throws {
                    guard written + count <= total else { throw violation("ZRLE : plus de pixels que la tuile") }
                    for k in 0..<count {
                        let i = written + k
                        buf.setPixel(x: tx + i % tw, y: ty + i / tw, b: c.0, g: c.1, r: c.2)
                    }
                    written += count
                }
                if !rle {
                    if paletteSize == 0 { // Raw (CPIXEL)
                        for _ in 0..<total { try put(try cpixel(), 1) }
                    } else if paletteSize == 1 { // uni
                        try put(palette[0], total)
                    } else if paletteSize <= 16 { // palette empaquetée, lignes alignées sur l'octet
                        let bits = paletteSize == 2 ? 1 : (paletteSize <= 4 ? 2 : 4)
                        for _ in 0..<th {
                            var bitsLeft = 0, cur: UInt8 = 0
                            for _ in 0..<tw {
                                if bitsLeft == 0 { cur = try byte(); bitsLeft = 8 }
                                bitsLeft -= bits
                                let idx = Int((cur >> UInt8(bitsLeft)) & UInt8((1 << bits) - 1))
                                guard idx < palette.count else { throw violation("ZRLE : index de palette invalide") }
                                try put(palette[idx], 1)
                            }
                        }
                    } else { throw violation("ZRLE : sous-encodage \(sub) réservé") }
                } else {
                    if paletteSize == 0 { // RLE simple
                        while written < total { let c = try cpixel(); try put(c, try runLength()) }
                    } else if paletteSize == 1 { throw violation("ZRLE : sous-encodage 129 réservé")
                    } else { // RLE avec palette
                        while written < total {
                            let raw = try byte()
                            let idx = Int(raw & 0x7f)
                            guard idx < palette.count else { throw violation("ZRLE : index de palette invalide") }
                            try put(palette[idx], raw & 0x80 != 0 ? try runLength() : 1)
                        }
                    }
                }
                tx += 64
            }
            ty += 64
        }
    }

    // MARK: Curseur

    /// Pseudo-encodage Cursor : pixels (4 octets) puis masque binaire (lignes alignées sur l'octet). Rend du BGRA
    /// avec alpha (255 là où le masque est à 1, sinon transparent).
    public static func decodeCursor(_ r: inout RFBByteReader, width: Int, height: Int) throws -> [UInt8] {
        let pixels = try r.take(width * height * 4)
        let maskRow = (width + 7) / 8
        let mask = try r.take(maskRow * height)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let bit = (mask[mask.startIndex + y * maskRow + x / 8] >> UInt8(7 - x % 8)) & 1
                guard bit != 0 else { continue }
                let s = pixels.startIndex + (y * width + x) * 4, d = (y * width + x) * 4
                out[d] = pixels[s]; out[d + 1] = pixels[s + 1]; out[d + 2] = pixels[s + 2]; out[d + 3] = 255
            }
        }
        return out
    }
}

/// Décompression zlib d'un flux persistant (ZRLE) par `Compression` : l'en-tête zlib (2 octets) n'apparaît qu'au premier
/// bloc, le reste est du deflate brut terminé par des vidages de synchronisation (Z_SYNC_FLUSH). Non `Sendable` :
/// possédé par un seul client.
public final class RFBInflater {
    private var stream: compression_stream
    private var sawHeader = false
    private var failed = false

    public init() {
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        stream = compression_stream(dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        dummy.deallocate()
        compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
    }

    deinit { compression_stream_destroy(&stream) }

    public func inflate(_ input: [UInt8], maxOutput: Int = 64 << 20) throws -> [UInt8] {
        guard !failed else { throw RFBError.protocolViolation("flux zlib en erreur") }
        var data = input[...]
        if !sawHeader {
            guard data.count >= 2 else { return [] }
            data = data.dropFirst(2); sawHeader = true
        }
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        let size = chunk.count
        var status = COMPRESSION_STATUS_OK
        if data.isEmpty { return [] }
        data.withUnsafeBufferPointer { ip in
            stream.src_ptr = ip.baseAddress!; stream.src_size = ip.count
            while true {
                chunk.withUnsafeMutableBufferPointer { cp in
                    stream.dst_ptr = cp.baseAddress!; stream.dst_size = size
                    status = compression_stream_process(&stream, 0)
                }
                let produced = size - stream.dst_size
                out.append(contentsOf: chunk[0..<produced])
                if status == COMPRESSION_STATUS_ERROR || out.count > maxOutput { break }
                if stream.src_size == 0 && produced < size { break }
                if produced == 0 { break }
            }
        }
        if status == COMPRESSION_STATUS_ERROR || out.count > maxOutput {
            failed = true
            throw RFBError.protocolViolation(status == COMPRESSION_STATUS_ERROR ? "flux zlib invalide" : "données ZRLE démesurées")
        }
        return out
    }
}
