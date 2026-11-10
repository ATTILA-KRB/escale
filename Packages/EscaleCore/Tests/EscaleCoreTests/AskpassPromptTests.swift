import Testing
@testable import EscaleCore

/// Les textes marqués « observé » ont été capturés (argv[1] de SSH_ASKPASS) avec OpenSSH_10.3p1 contre un sshd local ;
/// les autres sont des variantes tirées des sources d'OpenSSH, non observées ici.
@Suite("Askpass : classification des invites")
struct AskpassPromptTests {
    @Test func motDePasse_observe() {
        #expect(AskpassPromptClassifier.classify("rayan@127.0.0.1's password: ") == .password(userAtHost: "rayan@127.0.0.1"))
        #expect(AskpassPromptClassifier.classify("rayan@127.0.0.1's password:") == .password(userAtHost: "rayan@127.0.0.1"))
        // variante : utilisateur avec apostrophe / hôte IPv6
        #expect(AskpassPromptClassifier.classify("bob@[::1]:2222's password: ") == .password(userAtHost: "bob@[::1]:2222"))
    }

    @Test func clavierInteractifMotDePasse_observe() {
        // PAM (UsePAM yes) : « (user@host) Password: »
        #expect(AskpassPromptClassifier.classify("(rayan@127.0.0.1) Password:") == .password(userAtHost: "rayan@127.0.0.1"))
        #expect(AskpassPromptClassifier.classify("(rayan@127.0.0.1) Password: ") == .password(userAtHost: "rayan@127.0.0.1"))
    }

    @Test func codesDeVerification_variantes() {
        #expect(AskpassPromptClassifier.classify("(rayan@srv) Verification code: ") == .verificationCode(label: "Verification code:"))
        #expect(AskpassPromptClassifier.classify("(rayan@srv) Passcode or option (1-3): ") == .verificationCode(label: "Passcode or option (1-3):"))
        #expect(AskpassPromptClassifier.classify("(rayan@srv) One-time password (OATH) for `rayan': ") == .verificationCode(label: "One-time password (OATH) for `rayan':"))
        #expect(AskpassPromptClassifier.classify("(rayan@srv) ") == .verificationCode(label: ""))
    }

    @Test func phraseDePasse_observe() {
        #expect(AskpassPromptClassifier.classify("Enter passphrase for key 'ppkey': ") == .passphrase(keyPath: "ppkey"))
        #expect(AskpassPromptClassifier.classify("Enter passphrase for key '/Users/x/Mes Clés/id_ed25519': ")
            == .passphrase(keyPath: "/Users/x/Mes Clés/id_ed25519"))
        // variante (anciens ssh, sans « key » ni apostrophes)
        #expect(AskpassPromptClassifier.classify("Enter passphrase for /home/x/.ssh/id_rsa: ") == .passphrase(keyPath: "/home/x/.ssh/id_rsa"))
    }

    @Test func cleDHoteInconnue_observe() {
        let text = """
        The authenticity of host '[127.0.0.1]:2299 ([127.0.0.1]:2299)' can't be established.
        ED25519 key fingerprint is: SHA256:YAMabvvQox/whcbegIpTRRIJN9UNRgnAA+aXUdnzsDc
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])? 
        """
        #expect(AskpassPromptClassifier.classify(text) == .hostKeyConfirmation(
            keyType: "ED25519", fingerprint: "SHA256:YAMabvvQox/whcbegIpTRRIJN9UNRgnAA+aXUdnzsDc", host: "[127.0.0.1]:2299 ([127.0.0.1]:2299)"))
    }

    @Test func cleDHoteInconnue_variantes() {
        // Variante : sans « : » après « is » (ssh plus anciens), point final, RSA.
        let text = """
        The authenticity of host 'example.org (203.0.113.7)' can't be established.
        RSA key fingerprint is SHA256:abc+/def123.
        This host key is known by the following other names/addresses:
            ~/.ssh/known_hosts:3: other.example.org
        Are you sure you want to continue connecting (yes/no/[fingerprint])? 
        """
        #expect(AskpassPromptClassifier.classify(text) == .hostKeyConfirmation(
            keyType: "RSA", fingerprint: "SHA256:abc+/def123", host: "example.org (203.0.113.7)"))
        // Empreinte absente : reste une confirmation (jamais « autre »).
        #expect(AskpassPromptClassifier.classify("Are you sure you want to continue connecting (yes/no)? ")
            == .hostKeyConfirmation(keyType: nil, fingerprint: nil, host: nil))
    }

    @Test func cleDHoteModifiee() {
        // Texte observé sur stderr (ssh n'appelle PAS askpass dans ce cas) ; variantes des sources pour les invites.
        let observed = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        """
        #expect(AskpassPromptClassifier.classify(observed) == .hostKeyChanged)
        #expect(AskpassPromptClassifier.classify("Host key for [127.0.0.1]:2299 has changed and you have requested strict checking.") == .hostKeyChanged)
        #expect(AskpassPromptClassifier.classify("Warning: the ED25519 host key for 'x' differs from the key for the IP address '1.2.3.4'\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ") == .hostKeyChanged)
        // Prioritaire sur la confirmation.
        #expect(AskpassPromptClassifier.classify("WARNING: POSSIBLE DNS SPOOFING DETECTED!\nAre you sure you want to continue connecting (yes/no)? ") == .hostKeyChanged)
    }

    @Test func autres() {
        #expect(AskpassPromptClassifier.classify("Enter PIN for 'token': ") == .other)
        #expect(AskpassPromptClassifier.classify("") == .other)
        #expect(AskpassPromptClassifier.classify("n'importe quoi") == .other)
    }
}
