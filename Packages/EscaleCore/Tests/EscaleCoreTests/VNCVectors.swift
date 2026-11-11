// Vecteurs de reference generes par scripts/ hors depot (openssl des-ecb legacy, python pow/zlib/hashlib).
// Ne pas editer a la main.
enum VNCVectors {
    /// (mot de passe, defi 16 octets hex, reponse hex, cle DES hex) : DES d'OpenSSL 4.1 avec octets de cle bit-inverses.
    static let vncAuth: [(String, String, String, String)] = [
        ("password", "000102030405060708090a0b0c0d0e0f", "b866924125c8eebb9debc1db61c538e2", "0e86ceceeef64e26"),
        ("secret", "00112233445566778899aabbccddeeff", "f19b50471f60f42298e5c0147db50e1e", "cea6c64ea62e0000"),
        ("", "00000000000000000000000000000000", "8ca64de9c1b123a78ca64de9c1b123a7", "0000000000000000"),
        ("longpassword12", "101112131415161718191a1b1c1d1e1f", "bb6b3502a3e8c5554385c89918f24e0b", "36f676e60e86cece"),
        ("é€x", "6162636465666768696a6b6c6d6e6f70", "dca0ceaecb5738f2b2d99a9245d4ac73", "97fc1e0000000000"),
    ]
    static let modBase = "000000a139263059f28c105d1fb17c2390c192cfd3ac94af0f21ddb66cad4a268d116ece1738f7d93d9c172411e20b8f6b0d549b6f03675a1600a35a099950d836f675cc81e74ef5e8e25d940ed904759531985d5d9dc9f81818e811892f902bd23f0824128b2f330c5c7fd0a6a3a4506513270e269e0d37f2a74de452e6b438"
    static let modExp = "000000185f557203301850c5a38fd547923a736994e3bf911a61dbe22e44158bae97ba94d0eda82f8f6d05584ef8aa38922766581e27a1c08a6a63ec24ede6a46b4cb2424a23d5962217beaddbc496cb8e81973e0becd7b03898d190f9ebdacc0cb1e29c658cda1495e60af593bd04cf0fd630f1f29d0da9953f48f1a09f76b5"
    static let modPrime = "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece65381ffffffffffffffff"
    static let modResult = "1291080970c05dbe9fdd25cbe50ac944f95e71573d3dce2df3484cec8a8a546179691b91feb60f398d4ab3b9f813152217a7715fd4c940f3ab03f9608d1aa65362fb7c0fa1af67b59c4e4b60e4037f4c2e74243ef4c605320e1bbd0d7597b4c4f43469699eba17decddf261a859a6cfe4f0b59b1ef0b4e8cbd333fc2fa5da4da"
    /// Trois messages d'un meme flux zlib (Z_SYNC_FLUSH entre chacun) : "hello world "*50, octets 0..255 x4, "abc"*1000.
    static let zlibMessages: [String] = [
        "789cca48cdc9c95728cf2fca4951c818658fb2a9c406000000ffff",
        "6260646266616563e7e0e4e2e6e1e5e3171014121611151397909492969195935750545256515553d7d0d4d2d6d1d5d33730343236313533b7b0b4b2b6b1b5b37770747276717573f7f0f4f2f6f1f5f30f080c0a0e090d0b8f888c8a8e898d8b4f484c4a4e494d4bcfc8cccacec9cdcb2f282c2a2e292d2bafa8acaaaea9adab6f686c6a6e696d6befe8eceaeee9edeb9f3071d2e42953a74d9f3173d6ec3973e7cd5fb070d1e2254b972d5fb172d5ea356bd7addfb071d3e62d5bb76ddfb173d7ee3d7bf7ed3f70f0d0e123478f1d3f71f2d4e93367cf9dbf70f1d2e52b57af5dbf71f3d6ed3b77efdd7ff0f0d1e3274f9f3d7ff1f2d5eb376fdfbdfff0f1d3e72f5fbf7dfff1f3d7ef3f7ffffd1ff5ffa8ff47b2ff01000000ffff",
        "ecce310d000000c320ffae57193b4810403d0000e0dc000000ffff",
    ]
    /// Trois rectangles ZRLE successifs d'un meme flux (80x70 @0,0 ; 8x8 @100,0 ; 3x2 @100,20), octets du fil.
    static let zrleA = "0000002e789c629413e162e2e23a0184a1a1ab560d246e6066624cfef3fbd77f99660686ff60c8d060c8d8a403000000ffff"
    static let zrleB = "000000840c8da11104310cc48c0f1f360e0e5e6c1cbc383878f1e1c7aec495b8a28fa04633b2cb63fe1adc384cd3125661fdb8bd7ec1704e173cc36b79bf30870f60828002b950443b6dd0e77564508b49d6660fd99443087149546ed551cf34a44762dd30b5334f96b25116e5abc0e22e9d4a557dd5d1b6eea4b19ba7a5ceafebd7fd070000ffff"
    static let zrleC = "0000001a626564646462626266666661616165656551307400000000ffff"
    /// Empreinte SHA-256 des pixels BGRA de chaque region attendue (calculee depuis le motif, pas depuis le decodeur).
    static let zrleHashes: [String: String] = [
        "A": "37a6e813f01f98db42605fb0849320798c47ed797ad8fc811a87f471cdbd6e57",
        "B": "606ca95faff6b1c57b7ba6bd898199f46bcb293630b24a6092fff3e31ad47dc2",
        "C": "fcaff6913c55b781f03e7fef4e12e4bbe4b9a096933ba93710cfb9ca6e36cdb9",
    ]
    /// Pixels isoles attendus (x, y, b, g, r).
    static let zrlePoints: [(Int, Int, UInt8, UInt8, UInt8)] = [
        (0, 0, 30, 20, 10),
        (63, 63, 30, 20, 10),
        (64, 0, 10, 10, 200),
        (65, 1, 10, 10, 200),
        (79, 63, 10, 10, 200),
        (0, 64, 3, 2, 1),
        (64, 64, 0, 0, 255),
        (79, 69, 255, 0, 0),
        (100, 0, 0, 0, 0),
        (103, 3, 60, 90, 90),
        (107, 7, 140, 210, 210),
        (100, 20, 1, 1, 1),
        (101, 20, 5, 5, 5),
        (102, 21, 5, 5, 5),
        (101, 21, 2, 2, 2),
    ]
}
