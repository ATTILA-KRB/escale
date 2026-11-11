import CommonCrypto
import CryptoKit
import Foundation
import Testing
@testable import EscaleCore

@Suite("VNC : DES, authentification, arithmétique")
struct VNCCryptoTests {
    @Test func desVecteurClassique() {
        // Vecteur FIPS/Stallings : clé 133457799BBCDFF1, clair 0123456789ABCDEF.
        let c = VNCDES.cryptBlock(hexBytes("0123456789abcdef"), key: hexBytes("133457799bbcdff1"))
        #expect(hexString(c) == "85e813540f0ab405")
        #expect(VNCDES.cryptBlock(c, key: hexBytes("133457799bbcdff1"), decrypt: true) == hexBytes("0123456789abcdef"))
    }

    @Test func reponsesVNCContreOpenSSL() {
        for (pw, challenge, response, key) in VNCVectors.vncAuth {
            #expect(hexString(VNCDES.vncKey(password: pw)) == key, "clé de « \(pw) »")
            #expect(hexString(VNCDES.vncResponse(challenge: hexBytes(challenge), password: pw)) == response, "réponse pour « \(pw) »")
        }
    }

    @Test func desIdentiqueACommonCryptoSurDesBlocsAleatoires() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let key = (0..<8).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let block = (0..<8).map { _ in UInt8.random(in: 0...255, using: &rng) }
            var out = [UInt8](repeating: 0, count: 16); var moved = 0
            let st = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode), key, 8, nil, block, 8, &out, 16, &moved)
            #expect(st == kCCSuccess)
            #expect(VNCDES.cryptBlock(block, key: key) == Array(out[0..<8]))
        }
    }

    @Test func cleVNCCompleteEtInverseLesBits() {
        #expect(VNCDES.vncKey(password: "") == [UInt8](repeating: 0, count: 8))
        #expect(VNCDES.vncKey(password: "a") == [0x86, 0, 0, 0, 0, 0, 0, 0]) // 0x61 = 01100001 -> 10000110
        #expect(VNCDES.vncKey(password: "123456789").count == 8)
    }

    @Test func puissanceModulaireContrePython() throws {
        let r = try #require(RFBModularMath.modPow(base: hexBytes(VNCVectors.modBase), exponent: hexBytes(VNCVectors.modExp), modulus: hexBytes(VNCVectors.modPrime)))
        #expect(hexString(r) == VNCVectors.modResult)
        #expect(RFBModularMath.modPow(base: [5], exponent: [117], modulus: [19]) == [1])      // pow(5,117,19) = 1
        #expect(RFBModularMath.modPow(base: [4], exponent: [13], modulus: [0x01, 0xf1]) == [0x01, 0xbd]) // pow(4,13,497) = 445
        #expect(RFBModularMath.modPow(base: [4], exponent: [13], modulus: [10]) == nil) // module pair
        #expect(RFBModularMath.modPow(base: [200], exponent: [3], modulus: [19]) == nil) // base >= module
    }

    @Test func apple_remote_desktop_cote_serveur_retrouve_les_identifiants() throws {
        // Le « serveur » est écrit ici avec les mêmes primitives : DH sur le groupe de 1024 bits, clé AES = MD5(secret).
        let prime = hexBytes(VNCVectors.modPrime)
        let serverPriv = hexBytes(VNCVectors.modExp)
        let g: [UInt8] = [UInt8](repeating: 0, count: 126) + [0, 2]
        let serverPub = try #require(RFBModularMath.modPow(base: g, exponent: serverPriv, modulus: prime))
        let reply = try RFBAppleAuth.response(generator: 2, prime: prime, serverPublicKey: serverPub, username: "rayan", password: "pässword")
        #expect(reply.count == 128 + 128)
        let clientPub = Array(reply[128...])
        let shared = try #require(RFBModularMath.modPow(base: clientPub, exponent: serverPriv, modulus: prime))
        let key = Array(Insecure.MD5.hash(data: shared))
        let plain = try RFBAppleAuth.aes128ECB(Array(reply[0..<128]), key: key, encrypt: false)
        func field(_ r: Range<Int>) -> String { String(decoding: plain[r].prefix { $0 != 0 }, as: UTF8.self) }
        #expect(field(0..<64) == "rayan")
        #expect(field(64..<128) == "pässword")
    }

    @Test func apple_remote_desktop_refuse_des_parametres_invalides() {
        #expect(throws: RFBError.self) { try RFBAppleAuth.response(generator: 2, prime: [1, 3], serverPublicKey: [1, 2], username: "", password: "") }
        let prime = hexBytes(VNCVectors.modPrime)
        #expect(throws: RFBError.self) { try RFBAppleAuth.response(generator: 2, prime: prime, serverPublicKey: [1], username: "", password: "") }
    }
}

@Suite("VNC : touches et réglages")
struct VNCKeysAndSettingsTests {
    @Test func caracteresProduitsParLeClavierAzerty() {
        // La frappe suit le caractère produit, pas la position physique.
        #expect(RFBKeysym.keysym(keyCode: 12, characters: "a", base: "a", controlOrCommand: false) == 0x61)
        #expect(RFBKeysym.keysym(keyCode: 0, characters: "q", base: "q", controlOrCommand: false) == 0x71)
        #expect(RFBKeysym.keysym(keyCode: 14, characters: "é", base: "é", controlOrCommand: false) == 0xe9)
        #expect(RFBKeysym.keysym(keyCode: 21, characters: "{", base: "'", controlOrCommand: false) == 0x7b)
        #expect(RFBKeysym.keysym(keyCode: 14, characters: "€", base: "e", controlOrCommand: false) == 0x0100_20ac)
        #expect(RFBKeysym.keysym(keyCode: 8, characters: "\u{3}", base: "c", controlOrCommand: true) == 0x63)
        #expect(RFBKeysym.keysym(keyCode: 49, characters: " ", base: " ", controlOrCommand: false) == 0x20)
    }

    @Test func touchesSpecialesEtPaveNumerique() {
        #expect(RFBKeysym.keysym(keyCode: 36, characters: "\r", base: "\r", controlOrCommand: false) == 0xff0d)
        #expect(RFBKeysym.keysym(keyCode: 51, characters: "\u{7f}", base: "\u{7f}", controlOrCommand: false) == 0xff08)
        #expect(RFBKeysym.keysym(keyCode: 126, characters: "\u{f700}", base: "\u{f700}", controlOrCommand: false) == 0xff52)
        #expect(RFBKeysym.keysym(keyCode: 122, characters: "\u{f704}", base: "\u{f704}", controlOrCommand: false) == 0xffbe)
        #expect(RFBKeysym.keysym(keyCode: 82, characters: "0", base: "0", controlOrCommand: false) == 0xffb0)
        #expect(RFBKeysym.keysym(keyCode: 200, characters: "\u{f750}", base: nil, controlOrCommand: false) == nil)
        #expect(RFBKeysym.modifierKeys[56] == 0xffe1 && RFBKeysym.modifierKeys[55] == 0xffeb)
    }

    @Test func reglagesTolerantsEtValidation() throws {
        let d = try JSONDecoder().decode(VNCSettings.self, from: Data("{}".utf8))
        #expect(d == VNCSettings())
        #expect(d.shared && !d.viewOnly && d.scaling == .fit && d.encoding == .auto && d.viaSSHHostID == nil)
        let future = try JSONDecoder().decode(VNCSettings.self, from: Data(#"{"encoding":"tight","scaling":"zoom","viewOnly":true}"#.utf8))
        #expect(future.encoding == .auto && future.scaling == .fit && future.viewOnly)
        let id = UUID()
        let s = VNCSettings(viaSSHHostID: id, viewOnly: true, shared: false, encoding: .hextile, scaling: .actual)
        #expect(try JSONDecoder().decode(VNCSettings.self, from: JSONEncoder().encode(s)) == s)
        #expect(VNCSettings.validationErrors(s, hostID: id).count == 1)
        #expect(VNCSettings.validationErrors(s, hostID: UUID()).isEmpty)
        #expect(VNCSettings.validationErrors(s).isEmpty)
        let hostJSON = #"{"id":"\#(UUID().uuidString)","name":"n","host":"h","connectionProtocol":"vnc","vnc":{"scaling":"actual"}}"#
        let h = try JSONDecoder().decode(HostProfile.self, from: Data(hostJSON.utf8))
        #expect(h.vnc?.scaling == .actual && h.vnc?.shared == true)
        #expect(VNCSettings.passwordAccount(for: id) == "host-\(id.uuidString)")
    }

    @Test func listesDEncodages() {
        #expect(RFBEncoding.list(for: .auto) == [16, 5, 2, 1, 0, -239, -223])
        #expect(RFBEncoding.list(for: .raw) == [1, 0, -239, -223])
        #expect(RFBConfiguration(settings: VNCSettings(viewOnly: true, encoding: .hextile)).encodings == [5, 1, 0, -239, -223])
    }
}
