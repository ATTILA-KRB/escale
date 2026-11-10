import Foundation
import Testing
@testable import EscaleCore

private let sock = "/tmp/escale-x/m"

private func builder(_ profile: HostProfile, _ options: OpenSSHOptions = OpenSSHOptions()) throws -> OpenSSHCommandBuilder {
    try OpenSSHCommandBuilder(profile: profile, controlPath: sock, options: options)
}

@Suite("OpenSSHCommandBuilder")
struct OpenSSHCommandBuilderTests {
    @Test func maitreMinimal() throws {
        let b = try builder(HostProfile(name: "a", host: "h"))
        #expect(b.masterArguments() == [
            "-M", "-S", sock, "-N", "-o", "ControlPersist=no", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", "--", "h",
        ])
    }

    @Test func maitreCompletAvecPortUtilisateurCleEtOptionsInjectees() throws {
        let profile = HostProfile(name: "a", host: "srv", port: 2222, user: "bob", auth: .keyFile(path: "/k/id"))
        let opts = OpenSSHOptions(
            configFile: "/dev/null", userKnownHostsFile: "/t/kh", strictHostKeyChecking: .acceptNew,
            batchMode: false, connectTimeout: 3, serverAliveInterval: 1, serverAliveCountMax: 4, extraOptions: ["Compression=no"])
        #expect(try builder(profile, opts).masterArguments() == [
            "-M", "-S", sock, "-N", "-o", "ControlPersist=no", "-o", "BatchMode=no", "-o", "ConnectTimeout=3",
            "-o", "ServerAliveInterval=1", "-o", "ServerAliveCountMax=4", "-F", "/dev/null",
            "-p", "2222", "-i", "/k/id", "-o", "IdentitiesOnly=yes",
            "-o", "UserKnownHostsFile=/t/kh", "-o", "StrictHostKeyChecking=accept-new", "-o", "Compression=no",
            "--", "bob@srv",
        ])
    }

    @Test func proxyJumpMultiple() throws {
        let profile = HostProfile(name: "a", host: "cible", user: "u", jumpHosts: ["a@b1:2200", "b2"])
        let args = try builder(profile).masterArguments()
        let i = try #require(args.firstIndex(of: "-J"))
        #expect(args[i + 1] == "a@b1:2200,b2")
        #expect(args.suffix(2) == ["--", "u@cible"])
    }

    @Test func clientsSecondairesNeutralisentLeRepli() throws {
        let b = try builder(HostProfile(name: "a", host: "h", port: 22, user: "u"))
        let guardArgs = ["-o", "ControlMaster=no", "-o", "ProxyCommand=/usr/bin/false"]
        #expect(b.shellArguments() == ["-S", sock] + guardArgs + ["-tt", "-p", "22", "--", "u@h"])
        #expect(b.shellArguments(remoteCommand: "uptime") == ["-S", sock] + guardArgs + ["-tt", "-p", "22", "--", "u@h", "uptime"])
        #expect(b.sftpArguments() == ["-S", sock] + guardArgs + ["-p", "22", "-s", "--", "u@h", "sftp"])
        #expect(b.sftpArguments(verbose: true).contains("-v"))
        #expect(try b.controlArguments(.check) == ["-S", sock] + guardArgs + ["-p", "22", "-O", "check", "--", "u@h"])
        #expect(try b.controlArguments(.exit) == ["-S", sock] + guardArgs + ["-p", "22", "-O", "exit", "--", "u@h"])
    }

    @Test func secondairesNIncluentPasLesBastions() throws {
        let b = try builder(HostProfile(name: "a", host: "h", jumpHosts: ["j"]))
        #expect(!b.sftpArguments().contains("-J"))
        #expect(!b.shellArguments().contains("-J"))
    }

    @Test func forwardEtCancel() throws {
        let b = try builder(HostProfile(name: "a", host: "h"))
        let l = TunnelSpec(kind: .local, bindPort: 8080, destinationHost: "db", destinationPort: 5432)
        let d = TunnelSpec(kind: .dynamic, bindPort: 1080)
        #expect(try b.controlArguments(.cancel(d)).suffix(6) == ["-O", "cancel", "-D", "127.0.0.1:1080", "--", "h"])
        #expect(try b.controlArguments(.forward(l)).suffix(6) == ["-O", "forward", "-L", "127.0.0.1:8080:db:5432", "--", "h"])
    }

    @Test(arguments: ["-oProxyCommand=evil", "-h", "--", "-"])
    func hoteCommencantParTiretRefuse(host: String) {
        #expect(throws: OpenSSHCommandBuilderError.invalidHost(host)) { try builder(HostProfile(name: "a", host: host)) }
    }

    @Test func utilisateurCommencantParTiretRefuse() {
        #expect(throws: OpenSSHCommandBuilderError.invalidUser("-oProxyCommand=x")) {
            try builder(HostProfile(name: "a", host: "h", user: "-oProxyCommand=x"))
        }
    }

    @Test func autresEntreesInvalidesRefusees() {
        #expect(throws: OpenSSHCommandBuilderError.invalidHost("")) { try builder(HostProfile(name: "a", host: "")) }
        #expect(throws: OpenSSHCommandBuilderError.invalidHost("a b")) { try builder(HostProfile(name: "a", host: "a b")) }
        #expect(throws: OpenSSHCommandBuilderError.invalidHost("h\nx")) { try builder(HostProfile(name: "a", host: "h\nx")) }
        #expect(throws: OpenSSHCommandBuilderError.invalidPort(0)) { try builder(HostProfile(name: "a", host: "h", port: 0)) }
        #expect(throws: OpenSSHCommandBuilderError.invalidPort(70000)) { try builder(HostProfile(name: "a", host: "h", port: 70000)) }
        #expect(throws: OpenSSHCommandBuilderError.invalidJumpHost("-J")) { try builder(HostProfile(name: "a", host: "h", jumpHosts: ["-J"])) }
        #expect(throws: OpenSSHCommandBuilderError.invalidJumpHost("a,b")) { try builder(HostProfile(name: "a", host: "h", jumpHosts: ["a,b"])) }
        #expect(throws: OpenSSHCommandBuilderError.invalidKeyPath("")) { try builder(HostProfile(name: "a", host: "h", auth: .keyFile(path: ""))) }
        #expect(throws: OpenSSHCommandBuilderError.invalidOption("sansegal")) {
            try builder(HostProfile(name: "a", host: "h"), OpenSSHOptions(extraOptions: ["sansegal"]))
        }
        #expect(throws: OpenSSHCommandBuilderError.invalidControlPath("-x")) {
            try OpenSSHCommandBuilder(profile: HostProfile(name: "a", host: "h"), controlPath: "-x")
        }
    }

    @Test func tunnelInvalideRefuse() throws {
        let b = try builder(HostProfile(name: "a", host: "h"))
        #expect(throws: OpenSSHCommandBuilderError.self) { try b.controlArguments(.forward(TunnelSpec(kind: .local, bindPort: 0, destinationHost: "d", destinationPort: 1))) }
        #expect(throws: OpenSSHCommandBuilderError.self) { try b.controlArguments(.forward(TunnelSpec(kind: .local, bindPort: 1, destinationHost: "", destinationPort: 1))) }
    }

    @Test func environnementAskpassTransmisSansEtreImplemente() throws {
        let env = ["SSH_ASKPASS": "/x/askpass", "SSH_ASKPASS_REQUIRE": "force"]
        let b = try builder(HostProfile(name: "a", host: "h"), OpenSSHOptions(environment: env))
        #expect(b.environment == env)
    }

    @Test func aucuneInterpolationShell() throws {
        // Un hôte « dangereux » pour un shell reste UN seul argument, et ne commence pas par un tiret.
        let b = try builder(HostProfile(name: "a", host: "h;rm$IFS-rf", user: "u"))
        #expect(b.masterArguments().last == "u@h;rm$IFS-rf")
    }

    @Test func transportRefuseUnHoteInjecteSansLancerDeProcessus() async {
        let t = OpenSSHTransport(profile: HostProfile(name: "a", host: "-oProxyCommand=touch /tmp/pwned"))
        await #expect(throws: SSHTransportError.self) { try await t.connect() }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/pwned"))
        #expect(await t.masterProcessIdentifier == nil)
        await t.disconnect()
    }

    @Test func cheminDeSocketParDefautEstCourt() async throws {
        let long = "/tmp/" + String(repeating: "x", count: 120)
        // Hôte valide mais injoignable : seul le calcul du chemin nous intéresse.
        let ok = OpenSSHTransport(
            profile: HostProfile(name: "a", host: "127.0.0.1", port: 1), configuration: .init(ssh: OpenSSHOptions(configFile: "/dev/null", connectTimeout: 2), socketDirectory: long))
        _ = try? await ok.connect()
        let path = try #require(await ok.controlSocketPath)
        #expect(path.utf8.count <= OpenSSHTransport.maxControlPathBytes)
        #expect(path.hasPrefix("/tmp/escale-"))
        await ok.disconnect()
    }
}
