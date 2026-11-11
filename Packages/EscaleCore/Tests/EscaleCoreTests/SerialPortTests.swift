import Testing
import Foundation
import Darwin
@testable import EscaleCore

/// Faux port série : un pty dont le maître joue l'appareil, l'esclave est le « périphérique » ouvert par `SerialPort`.
private final class FakeDevice: @unchecked Sendable {
    var master: Int32 = -1
    var slavePath = ""

    init() throws {
        var m: Int32 = -1, s: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&m, &s, &name, nil, nil) == 0 else { throw PTYError(operation: "openpty", errnoValue: errno) }
        master = m
        slavePath = String(cString: name)
        Darwin.close(s) // seul le port ouvrira l'esclave
        _ = fcntl(m, F_SETFL, fcntl(m, F_GETFL) | O_NONBLOCK)
    }

    deinit { closeMaster() }
    func closeMaster() { if master >= 0 { Darwin.close(master); master = -1 } }

    func send(_ s: String) { let b = Array(s.utf8); _ = Darwin.write(master, b, b.count) }

    /// Lit côté appareil jusqu'à avoir au moins `count` octets (ou délai).
    func read(count: Int, timeout: Double = 3) -> [UInt8] {
        var out = [UInt8](); let end = Date().addingTimeInterval(timeout)
        while out.count < count && Date() < end {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = Darwin.read(master, &buf, 256)
            if n > 0 { out += buf[0..<n] } else { usleep(10_000) }
        }
        return out
    }

    func termiosOnMaster() -> termios { var t = termios(); _ = tcgetattr(master, &t); return t }
}

private func firstChunk(_ port: SerialPort, containing marker: String, timeout: Double = 3) async -> String {
    await withTaskGroup(of: String.self) { g in
        g.addTask {
            var acc = ""
            for await d in port.output { acc += String(decoding: d, as: UTF8.self); if acc.contains(marker) { return acc } }
            return acc
        }
        g.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); return "TIMEOUT" }
        let r = await g.next()!; g.cancelAll(); return r
    }
}

@Suite(.serialized) struct SerialPortTests {
    @Test func aller_retour_octets() async throws {
        let dev = try FakeDevice()
        let port = try SerialPort(settings: SerialSettings(devicePath: dev.slavePath))
        defer { port.kill() }
        dev.send("bonjour\r\n")
        let got = await firstChunk(port, containing: "bonjour")
        #expect(got.contains("bonjour"))
        port.write(Data("AT\r".utf8))
        #expect(dev.read(count: 3) == Array("AT\r".utf8))
    }

    @Test func reglages_termios_relus() throws {
        let dev = try FakeDevice()
        let s = SerialSettings(devicePath: dev.slavePath, baudRate: 9600, dataBits: 7, parity: .even, stopBits: 2, flowControl: .hardware)
        let port = try SerialPort(settings: s)
        defer { port.kill() }
        var t = port.currentTermios()!
        #expect(t.c_cflag & tcflag_t(CSIZE) == tcflag_t(CS7))
        #expect(t.c_cflag & tcflag_t(PARENB) != 0)
        #expect(t.c_cflag & tcflag_t(PARODD) == 0)
        #expect(t.c_cflag & tcflag_t(CSTOPB) != 0)
        #expect(t.c_cflag & tcflag_t(CCTS_OFLOW | CRTS_IFLOW) == tcflag_t(CCTS_OFLOW | CRTS_IFLOW))
        #expect(t.c_cflag & tcflag_t(CLOCAL | CREAD) == tcflag_t(CLOCAL | CREAD))
        #expect(cfgetospeed(&t) == 9600 && cfgetispeed(&t) == 9600)
        #expect(t.c_lflag & tcflag_t(ICANON | ECHO | ISIG) == 0) // mode brut
        // Même vue depuis le maître (l'appareil).
        var m = dev.termiosOnMaster()
        #expect(m.c_cflag & tcflag_t(CSIZE) == tcflag_t(CS7))
        #expect(cfgetospeed(&m) == 9600)
    }

    @Test func parite_impaire_8bits_flux_logiciel() throws {
        let dev = try FakeDevice()
        let port = try SerialPort(settings: SerialSettings(devicePath: dev.slavePath, baudRate: 19200, dataBits: 8, parity: .odd, stopBits: 1, flowControl: .software))
        defer { port.kill() }
        var t = port.currentTermios()!
        #expect(t.c_cflag & tcflag_t(CSIZE) == tcflag_t(CS8))
        #expect(t.c_cflag & tcflag_t(PARENB | PARODD) == tcflag_t(PARENB | PARODD))
        #expect(t.c_cflag & tcflag_t(CSTOPB) == 0)
        #expect(t.c_iflag & tcflag_t(IXON | IXOFF) == tcflag_t(IXON | IXOFF))
        #expect(t.c_cflag & tcflag_t(CCTS_OFLOW | CRTS_IFLOW) == 0)
        #expect(cfgetospeed(&t) == 19200)
    }

    @Test func debit_non_standard() async throws {
        let dev = try FakeDevice()
        for rate in [250_000, 921_600] {
            do {
                let port = try SerialPort(settings: SerialSettings(devicePath: dev.slavePath, baudRate: rate))
                var tt = port.currentTermios()!
                _ = cfgetospeed(&tt)
                port.kill()
                _ = await port.waitForExit()
            } catch let e as SerialPortError {
                // Un pty n'implémente pas IOSSIOSPEED : l'erreur doit être typée et lisible.
                #expect(e.description.contains("\(rate)"), "\(e)")
            }
        }
    }

    @Test func fermeture_idempotente_exited_0() async throws {
        let dev = try FakeDevice()
        let port = try SerialPort(settings: SerialSettings(devicePath: dev.slavePath))
        port.kill(); port.kill()
        #expect(await port.waitForExit() == .exited(0))
        #expect(port.endReason == .closedLocally)
        #expect(!port.isOpen)
        port.write(Data("x".utf8)) // sans effet
        #expect(port.sendBreak() == false)
        // Le port est rendu : on peut le rouvrir.
        let again = try SerialPort(settings: SerialSettings(devicePath: dev.slavePath))
        again.kill()
        _ = await again.waitForExit()
    }

    @Test func disparition_du_peripherique() async throws {
        let dev = try FakeDevice()
        let port = try SerialPort(settings: SerialSettings(devicePath: dev.slavePath))
        dev.closeMaster()
        let st = await port.waitForExit()
        #expect(st == .exited(SerialPort.deviceLostExitCode))
        guard case .deviceLost(let msg)? = port.endReason else { Issue.record("raison absente : \(String(describing: port.endReason))"); return }
        #expect(msg.contains("déconnecté"), "\(msg)")
    }

    @Test func second_open_occupe() throws {
        let dev = try FakeDevice()
        let port = try SerialPort(settings: SerialSettings(devicePath: dev.slavePath))
        defer { port.kill() }
        #expect(throws: SerialPortError.busy(dev.slavePath)) { try SerialPort(settings: SerialSettings(devicePath: dev.slavePath)) }
    }

    @Test func erreurs_typees() throws {
        #expect(throws: SerialPortError.notFound("/dev/cu.absent-escale")) { try SerialPort(settings: SerialSettings(devicePath: "/dev/cu.absent-escale")) }
        #expect(throws: SerialPortError.emptyPath) { try SerialPort(settings: SerialSettings(devicePath: "  ")) }
        #expect(throws: SerialPortError.notSerialDevice("/dev/null")) { try SerialPort(settings: SerialSettings(devicePath: "/dev/null")) }
        #expect(throws: SerialPortError.self) { try SerialPort(settings: SerialSettings(devicePath: "/dev/null", dataBits: 9)) }
        #expect(SerialPortError.busy("/dev/cu.x").description.contains("occupé"))
        #expect(SerialPortError.notFound("/dev/cu.x").description.contains("introuvable"))
        #expect(SerialPortError.permissionDenied("/dev/cu.x").description.contains("refusé"))
    }

    @Test func fin_de_ligne_et_echo() async throws {
        #expect(SerialLineEnding.cr.translate(Data("a\r".utf8)) == Data("a\r".utf8))
        #expect(SerialLineEnding.lf.translate(Data("a\r".utf8)) == Data("a\n".utf8))
        #expect(SerialLineEnding.crlf.translate(Data("a\rb\r\nc".utf8)) == Data("a\r\nb\r\nc".utf8))
        let dev = try FakeDevice()
        let port = try SerialPort(settings: SerialSettings(devicePath: dev.slavePath, localEcho: true, lineEnding: .crlf))
        defer { port.kill() }
        port.write(Data("ls\r".utf8))
        #expect(dev.read(count: 4) == Array("ls\r\n".utf8))
        let echoed = await firstChunk(port, containing: "ls\r\n")
        #expect(echoed.contains("ls\r\n"))
    }

    @Test func break_et_lignes_de_controle() throws {
        let dev = try FakeDevice()
        let port = try SerialPort(settings: SerialSettings(devicePath: dev.slavePath))
        defer { port.kill() }
        // Observé sur un pty : tcsendbreak réussit (rien n'arrive côté maître) ; TIOCMBIS/TIOCMGET sont refusés
        // (pas de lignes de modem) : DTR/RTS ne sont vérifiables que sur un vrai port, le refus doit rester propre.
        #expect(port.sendBreak())
        #expect(port.setLine(.dtr, high: true) == false)
        #expect(port.modemBits() == nil)
        #expect(port.toggleLine(.rts) == nil)
    }

    @Test func decouverte_ne_plante_pas() {
        let l = SerialPortDiscovery.list()
        #expect(l.allSatisfy { $0.path.hasPrefix("/dev/cu.") })
        let tmp = NSTemporaryDirectory() + "escale-serial-disc-\(getpid())"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        for n in ["cu.usbserial-1", "tty.usbserial-1", "cu.Bluetooth"] { FileManager.default.createFile(atPath: "\(tmp)/\(n)", contents: nil) }
        #expect(SerialPortDiscovery.devPorts(directory: tmp).map(\.name) == ["Bluetooth", "usbserial-1"])
    }

    @Test func reglages_decodage_tolerant() throws {
        let s = try JSONDecoder().decode(SerialSettings.self, from: Data("{}".utf8))
        #expect(s == SerialSettings())
        #expect(s.localEcho == false && s.lineEnding == .cr)
        let t = try JSONDecoder().decode(SerialSettings.self, from: JSONEncoder().encode(SerialSettings(devicePath: "/dev/cu.a", localEcho: true, lineEnding: .crlf)))
        #expect(t.localEcho && t.lineEnding == .crlf)
        #expect(SerialSettings.validationErrors(SerialSettings(devicePath: "/dev/cu.a", dataBits: 9, stopBits: 3)).count == 2)
        #expect(SerialSettings.validationErrors(SerialSettings(devicePath: "/dev/cu.a")).isEmpty)
    }
}
