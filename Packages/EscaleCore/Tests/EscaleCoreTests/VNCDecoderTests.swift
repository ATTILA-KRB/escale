import CryptoKit
import Foundation
import Testing
@testable import EscaleCore

/// Décodeurs sur des rectangles synthétiques : les pixels attendus viennent du motif construit, pas du décodeur.
@Suite("VNC : décodeurs d'encodages")
struct VNCDecoderTests {
    typealias RGB = (b: UInt8, g: UInt8, r: UInt8)

    func fb(_ w: Int, _ h: Int) throws -> RFBFramebuffer { let f = RFBFramebuffer(); try f.resize(width: w, height: h); return f }
    func px(_ b: UInt8, _ g: UInt8, _ r: UInt8) -> [UInt8] { [b, g, r, 0] }
    func expectPixel(_ f: RFBFramebuffer, _ x: Int, _ y: Int, _ e: RGB, _ note: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        let p = f.pixel(x: x, y: y)
        #expect(p?.b == e.b && p?.g == e.g && p?.r == e.r, "pixel (\(x),\(y)) \(note) : \(String(describing: p))", sourceLocation: sourceLocation)
    }

    @Test func raw() throws {
        let f = try fb(4, 4)
        var r = RFBByteReader(px(1, 2, 3) + px(4, 5, 6) + px(7, 8, 9) + px(10, 11, 12))
        try f.withPixels { try RFBDecoders.decodeRaw(&r, rect: RFBRect(x: 1, y: 1, width: 2, height: 2), into: $0) }
        expectPixel(f, 1, 1, (1, 2, 3)); expectPixel(f, 2, 1, (4, 5, 6)); expectPixel(f, 1, 2, (7, 8, 9)); expectPixel(f, 2, 2, (10, 11, 12))
        expectPixel(f, 0, 0, (0, 0, 0)); expectPixel(f, 3, 3, (0, 0, 0))
        #expect(r.consumed == 16)
    }

    @Test func rawIncompletDemandeLeTotal() throws {
        let f = try fb(4, 4)
        var r = RFBByteReader(Array(repeating: 0, count: 10))
        do {
            try f.withPixels { try RFBDecoders.decodeRaw(&r, rect: RFBRect(x: 0, y: 0, width: 2, height: 2), into: $0) }
            Issue.record("devait lever")
        } catch let n as RFBNeedMoreData { #expect(n.total == 16) }
    }

    @Test func copyRectAvecChevauchement() throws {
        let f = try fb(6, 1)
        var raw6: [UInt8] = []
        for i in 0..<6 { raw6 += px(UInt8(i * 10), 0, 0) }
        var r = RFBByteReader(raw6)
        try f.withPixels { try RFBDecoders.decodeRaw(&r, rect: RFBRect(x: 0, y: 0, width: 6, height: 1), into: $0) }
        var c = RFBByteReader(be16(0) + be16(0))
        try f.withPixels { try RFBDecoders.decodeCopyRect(&c, rect: RFBRect(x: 1, y: 0, width: 4, height: 1), into: $0) }
        // Source 0..3 copiée en 1..4 : 0, 0, 10, 20, 30, 50.
        for (x, v) in [0, 0, 10, 20, 30, 50].enumerated() { expectPixel(f, x, 0, (UInt8(v), 0, 0)) }
        var bad = RFBByteReader(be16(4) + be16(0))
        #expect(throws: RFBError.self) { try f.withPixels { try RFBDecoders.decodeCopyRect(&bad, rect: RFBRect(x: 0, y: 0, width: 4, height: 1), into: $0) } }
    }

    @Test func rre() throws {
        let f = try fb(10, 10)
        // 2 sous-rectangles dans un rectangle 8×8 en (1,1) : fond (10,20,30) ; (50,60,70) en (2,2) 3×1 ; (80,90,100) en (7,7) 1×1.
        let data = be32(2) + px(10, 20, 30) + px(50, 60, 70) + be16(1) + be16(1) + be16(3) + be16(1) + px(80, 90, 100) + be16(6) + be16(6) + be16(1) + be16(1)
        var r = RFBByteReader(data)
        try f.withPixels { try RFBDecoders.decodeRRE(&r, rect: RFBRect(x: 1, y: 1, width: 8, height: 8), into: $0) }
        expectPixel(f, 1, 1, (10, 20, 30)); expectPixel(f, 8, 8, (10, 20, 30)); expectPixel(f, 0, 0, (0, 0, 0)); expectPixel(f, 9, 9, (0, 0, 0))
        expectPixel(f, 2, 2, (50, 60, 70)); expectPixel(f, 4, 2, (50, 60, 70)); expectPixel(f, 5, 2, (10, 20, 30)); expectPixel(f, 7, 7, (80, 90, 100))
    }

    @Test func rreRefuseUnSousRectangleHorsDuRectangle() throws {
        let f = try fb(10, 10)
        var r = RFBByteReader(be32(1) + px(0, 0, 0) + px(1, 1, 1) + be16(4) + be16(0) + be16(5) + be16(1))
        #expect(throws: RFBError.self) { try f.withPixels { try RFBDecoders.decodeRRE(&r, rect: RFBRect(x: 0, y: 0, width: 8, height: 8), into: $0) } }
    }

    /// Rectangle 20×18 : tuiles 16×16, 4×16, 16×2, 4×2.
    var hextileData: [UInt8] {
        var d: [UInt8] = []
        // Tuile 0 : fond + premier plan + 2 sous-rectangles (premier plan) : (0,0) 2×2 et (15,15) 1×1.
        d += [2 | 4 | 8] + px(1, 1, 1) + px(200, 100, 50) + [2] + [0x00, 0x11] + [0xff, 0x00]
        // Tuile 1 (4×16) : aucun drapeau : réutilise le fond (1,1,1).
        d += [0]
        // Tuile 2 (16×2) : sous-rectangle coloré : (3,0) 2×1 en (9,9,9) ; fond conservé.
        d += [8 | 16] + [1] + px(9, 9, 9) + [0x30, 0x10]
        // Tuile 3 (4×2) brute.
        d += [1]
        for i in 0..<8 { let v = UInt8(i); d += px(v, v + 1, v + 2) }
        return d
    }

    @Test func hextile() throws {
        let f = try fb(20, 18)
        var r = RFBByteReader(hextileData)
        try f.withPixels { try RFBDecoders.decodeHextile(&r, rect: RFBRect(x: 0, y: 0, width: 20, height: 18), into: $0) }
        expectPixel(f, 0, 0, (200, 100, 50)); expectPixel(f, 1, 1, (200, 100, 50)); expectPixel(f, 2, 2, (1, 1, 1))
        expectPixel(f, 15, 15, (200, 100, 50)); expectPixel(f, 14, 15, (1, 1, 1))
        expectPixel(f, 16, 0, (1, 1, 1)); expectPixel(f, 19, 15, (1, 1, 1))
        expectPixel(f, 3, 16, (9, 9, 9)); expectPixel(f, 4, 16, (9, 9, 9)); expectPixel(f, 5, 16, (1, 1, 1)); expectPixel(f, 0, 17, (1, 1, 1))
        expectPixel(f, 16, 16, (0, 1, 2)); expectPixel(f, 19, 16, (3, 4, 5)); expectPixel(f, 16, 17, (4, 5, 6)); expectPixel(f, 19, 17, (7, 8, 9))
        #expect(r.consumed == hextileData.count)
    }

    @Test func hextileTronqueRelanceDepuisLeDebut() throws {
        let data = hextileData
        for cut in [0, 1, 5, 12, data.count / 2, data.count - 1] {
            let f = try fb(20, 18)
            var r = RFBByteReader(Array(data.prefix(cut)))
            do {
                try f.withPixels { try RFBDecoders.decodeHextile(&r, rect: RFBRect(x: 0, y: 0, width: 20, height: 18), into: $0) }
                Issue.record("coupure à \(cut) : devait lever")
            } catch let n as RFBNeedMoreData { #expect(n.total > cut, "coupure \(cut) : total \(n.total)") }
        }
    }

    @Test func hextileRefuseUnSousRectangleHorsTuile() throws {
        let f = try fb(16, 16)
        var r = RFBByteReader([8 | 4] + px(1, 1, 1) + [1, 0xf0, 0x30]) // x=15 largeur 4 : déborde
        #expect(throws: RFBError.self) { try f.withPixels { try RFBDecoders.decodeHextile(&r, rect: RFBRect(x: 0, y: 0, width: 16, height: 16), into: $0) } }
    }

    @Test func rectanglesHorsEcranRefuses() throws {
        let f = try fb(4, 4)
        var r = RFBByteReader(Array(repeating: 0, count: 400))
        #expect(throws: RFBError.self) { try f.withPixels { try RFBDecoders.decodeRaw(&r, rect: RFBRect(x: 3, y: 3, width: 4, height: 4), into: $0) } }
        #expect(throws: RFBError.self) { try f.resize(width: 0, height: 5) }
        #expect(throws: RFBError.self) { try f.resize(width: 65000, height: 65000) }
    }

    @Test func curseurAvecMasque() throws {
        // 3×2 ; masque : ligne 0 = 101, ligne 1 = 010 (bits de poids fort d'abord).
        var pixels: [UInt8] = []
        for i in 0..<6 { pixels += px(UInt8(i + 1), 0, UInt8(100 + i)) }
        var r = RFBByteReader(pixels + [0b1010_0000, 0b0100_0000])
        let c = try RFBDecoders.decodeCursor(&r, width: 3, height: 2)
        let alpha = (0..<6).map { c[$0 * 4 + 3] }
        #expect(alpha == [255, 0, 255, 0, 255, 0])
        #expect(Array(c[0..<4]) == [1, 0, 100, 255]); #expect(Array(c[4..<8]) == [0, 0, 0, 0]); #expect(Array(c[16..<20]) == [5, 0, 104, 255])
    }

    // MARK: ZRLE

    func regionHash(_ f: RFBFramebuffer, _ x0: Int, _ y0: Int, _ w: Int, _ h: Int) -> String {
        let s = f.snapshot()
        var bytes: [UInt8] = []
        for y in y0..<y0 + h { for x in x0..<x0 + w { let i = (y * s.width + x) * 4; bytes.append(s.bgra[i]); bytes.append(s.bgra[i + 1]); bytes.append(s.bgra[i + 2]); bytes.append(255) } }
        // Le vecteur est haché en b, g, r, 255 (ordre du tampon).
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @Test func flotZlibPersistantParMessages() throws {
        let inflater = RFBInflater()
        let expected: [[UInt8]] = [
            Array(String(repeating: "hello world ", count: 50).utf8),
            Array((0..<1024).map { UInt8($0 % 256) }),
            Array(String(repeating: "abc", count: 1000).utf8),
        ]
        for (hex, e) in zip(VNCVectors.zlibMessages, expected) { #expect(try inflater.inflate(hexBytes(hex)) == e) }
    }

    @Test func zrleTroisRectanglesDUnMemeFlux() throws {
        let f = try fb(128, 100)
        let inflater = RFBInflater()
        let rects = [("A", VNCVectors.zrleA, RFBRect(x: 0, y: 0, width: 80, height: 70)),
                     ("B", VNCVectors.zrleB, RFBRect(x: 100, y: 0, width: 8, height: 8)),
                     ("C", VNCVectors.zrleC, RFBRect(x: 100, y: 20, width: 3, height: 2))]
        for (name, hex, rect) in rects {
            let wire = hexBytes(hex)
            var r = RFBByteReader(wire)
            try f.withPixels { try RFBDecoders.decodeZRLE(&r, rect: rect, into: $0, inflater: inflater) }
            #expect(r.consumed == wire.count, "rectangle \(name)")
            #expect(regionHash(f, rect.x, rect.y, rect.width, rect.height) == VNCVectors.zrleHashes[name], "empreinte du rectangle \(name)")
        }
        for (x, y, b, g, r) in VNCVectors.zrlePoints { expectPixel(f, x, y, (b, g, r)) }
        expectPixel(f, 50, 90, (0, 0, 0), "hors rectangles")
    }

    @Test func zrleTronqueDemandeLaLongueurComplete() throws {
        let f = try fb(128, 100)
        let wire = hexBytes(VNCVectors.zrleA)
        var r = RFBByteReader(Array(wire.prefix(wire.count - 3)))
        do {
            try f.withPixels { try RFBDecoders.decodeZRLE(&r, rect: RFBRect(x: 0, y: 0, width: 80, height: 70), into: $0, inflater: RFBInflater()) }
            Issue.record("devait lever")
        } catch let n as RFBNeedMoreData { #expect(n.total == wire.count) }
    }

    @Test func zrleTuilesInvalides() throws {
        let f = try fb(8, 8)
        let rect = RFBRect(x: 0, y: 0, width: 8, height: 8)
        // Index de palette hors palette (palette de 2, index 3 dans une palette RLE de taille 2).
        let bad = [UInt8(128 + 2), 1, 2, 3, 4, 5, 6, 0x05]
        #expect(throws: RFBError.self) { try f.withPixels { try RFBDecoders.decodeZRLETiles(bad, rect: rect, into: $0) } }
        // Sous-encodage réservé (17).
        #expect(throws: RFBError.self) { try f.withPixels { try RFBDecoders.decodeZRLETiles([17] + [UInt8](repeating: 0, count: 60), rect: rect, into: $0) } }
        // Run plus long que la tuile.
        #expect(throws: RFBError.self) { try f.withPixels { try RFBDecoders.decodeZRLETiles([128, 1, 2, 3, 255, 255], rect: rect, into: $0) } }
        // Tuile tronquée.
        #expect(throws: RFBError.self) { try f.withPixels { try RFBDecoders.decodeZRLETiles([0, 1, 2], rect: rect, into: $0) } }
    }

    @Test func zlibInvalideEstUneErreurDeProtocole() {
        let inflater = RFBInflater()
        #expect(throws: RFBError.self) { try inflater.inflate([0x78, 0x9c] + [UInt8](repeating: 0xff, count: 32)) }
    }
}
