import Foundation
import Darwin

/// Erreurs d'ouverture ou de configuration d'un port série (messages en français, affichés dans le panneau).
public enum SerialPortError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyPath
    case notFound(String)
    case busy(String)
    case permissionDenied(String)
    case notSerialDevice(String)
    case invalidSettings(String)
    case system(operation: String, errnoValue: Int32)

    public var description: String {
        switch self {
        case .emptyPath: "Aucun port série choisi."
        case .notFound(let p): "Port série introuvable : \(p) (périphérique débranché ?)."
        case .busy(let p): "Port série occupé : \(p) est déjà utilisé par une autre session ou un autre programme."
        case .permissionDenied(let p): "Accès refusé au port série \(p) (permissions du périphérique)."
        case .notSerialDevice(let p): "\(p) n'est pas un port série (terminal non reconnu)."
        case .invalidSettings(let m): "Réglages série invalides : \(m)"
        case .system(let op, let e): "\(op) : \(String(cString: strerror(e)))"
        }
    }
}

/// Fin d'une session série : fermeture locale ou disparition du périphérique.
public enum SerialEndReason: Equatable, Sendable, CustomStringConvertible {
    case closedLocally
    case deviceLost(String)

    public var description: String {
        switch self {
        case .closedLocally: "Port série fermé."
        case .deviceLost(let m): m
        }
    }
}

/// Fin de ligne ajoutée à l'envoi quand le moteur de terminal émet Entrée (CR).
public enum SerialLineEnding: String, Codable, CaseIterable, Sendable {
    case cr, lf, crlf

    public var bytes: [UInt8] {
        switch self { case .cr: [0x0D]; case .lf: [0x0A]; case .crlf: [0x0D, 0x0A] }
    }

    /// Remplace chaque CR de la saisie par la fin de ligne choisie. Un LF qui suit immédiatement un CR est absorbé
    /// quand la fin de ligne contient déjà un LF (collage de texte CRLF).
    public func translate(_ data: Data) -> Data {
        if self == .cr { return data }
        var out = [UInt8](); out.reserveCapacity(data.count + 8)
        var previousCR = false
        for b in data {
            if b == 0x0D { out.append(contentsOf: bytes); previousCR = true; continue }
            if b == 0x0A && previousCR { previousCR = false; continue }
            previousCR = false
            out.append(b)
        }
        return Data(out)
    }
}

/// Port série (termios) branché sur un panneau de terminal.
///
/// Ouverture `O_RDWR|O_NOCTTY|O_NONBLOCK` puis `TIOCEXCL` (accès exclusif : une seconde ouverture échoue en EBUSY),
/// mode brut (`cfmakeraw`), vitesse (`cfsetspeed`, ou `IOSSIOSPEED` pour les débits non standard), bits de données,
/// parité, bits de stop, contrôle de flux. Lecture par `DispatchSource`, écriture sur une file dédiée.
/// Concurrence : le descripteur et le statut sont protégés par `lock` ; la classe est donc `@unchecked Sendable`.
public final class SerialPort: TerminalByteStream, @unchecked Sendable {
    /// Code de sortie annoncé quand le périphérique disparaît (EX_IOERR) ; `.exited(0)` après fermeture locale.
    public static let deviceLostExitCode: Int32 = 74

    public let output: AsyncStream<Data>
    public let path: String
    public let settings: SerialSettings

    private let continuation: AsyncStream<Data>.Continuation
    private let registryKey: String
    private let readQueue = DispatchQueue(label: "escale.serial.read")
    private let writeQueue = DispatchQueue(label: "escale.serial.write")
    private let lock = NSLock()

    // Protégé par `lock`
    private var fd: Int32
    private var closing = false
    private var finished = false
    private var reason: SerialEndReason?
    private var status: PTYExitStatus?
    private var waiters: [CheckedContinuation<PTYExitStatus, Never>] = []

    // Protégé par `readQueue`
    private var readSource: DispatchSourceRead?

    /// Ouvre et configure le port. Lève `SerialPortError` (le descripteur est refermé en cas d'échec).
    public init(settings: SerialSettings) throws {
        let path = settings.devicePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { throw SerialPortError.emptyPath }
        if let m = SerialSettings.validationErrors(settings).first { throw SerialPortError.invalidSettings(m) }
        // Deux sessions du même processus sur un même port : refusé d'emblée (TIOCEXCL ne l'impose pas à tous les
        // pilotes, ni aux pty), avec le même message qu'un port pris par un autre programme.
        let key = Self.registryKey(path)
        guard Self.claim(key) else { throw SerialPortError.busy(path) }
        var claimed = true
        defer { if claimed { Self.release(key) } }
        let d = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if d < 0 {
            switch errno {
            case ENOENT, ENXIO, ENODEV, ENOTDIR: throw SerialPortError.notFound(path)
            case EBUSY: throw SerialPortError.busy(path)
            case EACCES, EPERM: throw SerialPortError.permissionDenied(path)
            default: throw SerialPortError.system(operation: "ouverture de \(path)", errnoValue: errno)
            }
        }
        var ok = false
        defer { if !ok { Darwin.close(d) } }
        _ = fcntl(d, F_SETFD, FD_CLOEXEC)
        guard isatty(d) != 0 else { throw SerialPortError.notSerialDevice(path) }
        // Accès exclusif : un second open() (même processus compris) échoue ensuite en EBUSY.
        if ioctl(d, UInt(TIOCEXCL)) != 0 {
            if errno == EBUSY { throw SerialPortError.busy(path) }
            throw SerialPortError.system(operation: "accès exclusif à \(path)", errnoValue: errno)
        }
        try Self.configure(fd: d, settings: settings)
        tcflush(d, TCIOFLUSH)

        self.path = path
        self.registryKey = key
        claimed = false
        self.settings = settings
        self.fd = d
        var cont: AsyncStream<Data>.Continuation!
        output = AsyncStream<Data>(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        ok = true
        startReading()
    }

    // MARK: Ports tenus par ce processus

    private nonisolated(unsafe) static var held = Set<String>()
    private static let heldLock = NSLock()
    private static func registryKey(_ path: String) -> String {
        path.withCString { p in realpath(p, nil).map { defer { free($0) }; return String(cString: $0) } } ?? path
    }
    private static func claim(_ key: String) -> Bool {
        heldLock.lock(); defer { heldLock.unlock() }
        return held.insert(key).inserted
    }
    private static func release(_ key: String) {
        heldLock.lock(); held.remove(key); heldLock.unlock()
    }

    // MARK: Configuration termios

    private static let iossiospeed = UInt(0x8008_5402) // _IOW('T', 2, speed_t) : IOSSIOSPEED (IOKit/serial/ioss.h)
    private static let standardRates: Set<Int> = [50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400, 4800, 9600,
                                                  14400, 19200, 28800, 38400, 57600, 76800, 115_200, 230_400]

    static func configure(fd: Int32, settings s: SerialSettings) throws {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else {
            if errno == ENOTTY { throw SerialPortError.notSerialDevice("le périphérique") }
            throw SerialPortError.system(operation: "lecture des réglages", errnoValue: errno)
        }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB)
        switch s.dataBits {
        case 5: t.c_cflag |= tcflag_t(CS5)
        case 6: t.c_cflag |= tcflag_t(CS6)
        case 7: t.c_cflag |= tcflag_t(CS7)
        default: t.c_cflag |= tcflag_t(CS8)
        }
        switch s.parity {
        case .none: break
        case .even: t.c_cflag |= tcflag_t(PARENB)
        case .odd: t.c_cflag |= tcflag_t(PARENB | PARODD)
        }
        if s.stopBits == 2 { t.c_cflag |= tcflag_t(CSTOPB) }
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        t.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        switch s.flowControl {
        case .none: break
        case .hardware: t.c_cflag |= tcflag_t(CCTS_OFLOW | CRTS_IFLOW)   // CRTSCTS
        case .software: t.c_iflag |= tcflag_t(IXON | IXOFF)
        }
        // Lecture non bloquante : rend la main dès qu'un octet est disponible.
        withUnsafeMutablePointer(to: &t.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { $0[Int(VMIN)] = 1; $0[Int(VTIME)] = 0 }
        }
        let standard = standardRates.contains(s.baudRate)
        if cfsetspeed(&t, speed_t(standard ? s.baudRate : 9600)) != 0 {
            throw SerialPortError.invalidSettings("débit \(s.baudRate) bauds refusé")
        }
        guard tcsetattr(fd, TCSANOW, &t) == 0 else {
            throw SerialPortError.system(operation: "application des réglages", errnoValue: errno)
        }
        if !standard {
            var speed = speed_t(s.baudRate)
            if ioctl(fd, iossiospeed, &speed) != 0 {
                throw SerialPortError.invalidSettings("débit \(s.baudRate) bauds non pris en charge par ce port (\(String(cString: strerror(errno))))")
            }
        }
    }

    /// Réglages termios relus sur le descripteur du port (vérification, diagnostic). `nil` si le port est fermé.
    public func currentTermios() -> termios? {
        lock.lock(); defer { lock.unlock() }
        guard !closing, fd >= 0 else { return nil }
        var t = termios()
        return tcgetattr(fd, &t) == 0 ? t : nil
    }

    // MARK: Lecture

    private func startReading() {
        let descriptor = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
        readSource = src
        src.setEventHandler { [weak self] in self?.readAvailable(descriptor) }
        src.setCancelHandler { [weak self] in self?.finishAfterCancel() }
        src.resume()
    }

    /// Sur `readQueue`.
    private func readAvailable(_ descriptor: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if n > 0 { continuation.yield(Data(buf[0..<n])); if n < buf.count { return }; continue }
            if n == 0 { deviceLost("le périphérique a fermé la liaison (fin de fichier)"); return }
            switch errno {
            case EINTR: continue
            case EAGAIN: return
            case ENXIO, ENODEV, EIO, EBADF: deviceLost("le périphérique a disparu (\(String(cString: strerror(errno))))"); return
            default: deviceLost("erreur de lecture (\(String(cString: strerror(errno))))"); return
            }
        }
    }

    private func deviceLost(_ detail: String) {
        lock.lock()
        if closing { lock.unlock(); return }
        closing = true
        reason = .deviceLost("Port série \(path) déconnecté : \(detail).")
        lock.unlock()
        readSource?.cancel()
    }

    /// Sur `readQueue` (gestionnaire d'annulation) : ferme, termine le flux, réveille les attentes.
    private func finishAfterCancel() {
        lock.lock()
        let d = fd
        fd = -1
        let why = reason ?? .closedLocally
        reason = why
        lock.unlock()
        if d >= 0 { Darwin.close(d) }
        Self.release(registryKey)
        if case .deviceLost(let m) = why { continuation.yield(Data("\r\n\u{1b}[2m[\(m)]\u{1b}[0m\r\n".utf8)) }
        continuation.finish()
        readSource = nil
        let st: PTYExitStatus
        switch why { case .closedLocally: st = .exited(0); case .deviceLost: st = .exited(Self.deviceLostExitCode) }
        lock.lock()
        finished = true
        status = st
        let ws = waiters
        waiters = []
        lock.unlock()
        ws.forEach { $0.resume(returning: st) }
    }

    // MARK: TerminalByteStream

    /// Raison de la fin (nil tant que le port est ouvert).
    public var endReason: SerialEndReason? { lock.lock(); defer { lock.unlock() }; return finished ? reason : nil }

    public var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return !closing && fd >= 0 }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let payload = settings.lineEnding.translate(data)
        if settings.localEcho { continuation.yield(Self.echoForm(payload)) }
        writeQueue.async { [self] in
            var offset = 0
            let bytes = [UInt8](payload)
            while offset < bytes.count {
                lock.lock()
                if closing || fd < 0 { lock.unlock(); return }
                let d = fd
                let n = bytes.withUnsafeBytes { Darwin.write(d, $0.baseAddress! + offset, bytes.count - offset) }
                let err = errno
                lock.unlock()
                if n > 0 { offset += n; continue }
                if n < 0 && err == EINTR { continue }
                if n < 0 && (err == EAGAIN || err == EWOULDBLOCK) {
                    var p = pollfd(fd: d, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 100)
                    continue
                }
                if n < 0 && (err == ENXIO || err == EIO || err == ENODEV) {
                    readQueue.async { [self] in deviceLost("écriture impossible (\(String(cString: strerror(err))))") }
                }
                return
            }
        }
    }

    /// Écho local : fins de ligne ramenées à CRLF, retour arrière visible.
    static func echoForm(_ data: Data) -> Data {
        var out = [UInt8]()
        var previousCR = false
        for b in data {
            switch b {
            case 0x0D: out.append(contentsOf: [0x0D, 0x0A]); previousCR = true; continue
            case 0x0A: if !previousCR { out.append(contentsOf: [0x0D, 0x0A]) }
            case 0x7F, 0x08: out.append(contentsOf: [0x08, 0x20, 0x08])
            default: out.append(b)
            }
            previousCR = false
        }
        return Data(out)
    }

    public func resize(columns: Int, rows: Int) {}

    /// Fermeture locale immédiate. Idempotente.
    public func kill() {
        lock.lock()
        if closing { lock.unlock(); return }
        closing = true
        reason = .closedLocally
        lock.unlock()
        readQueue.async { [self] in readSource?.cancel() }
    }

    public func waitForExit() async -> PTYExitStatus {
        await withCheckedContinuation { (c: CheckedContinuation<PTYExitStatus, Never>) in
            lock.lock()
            if let st = status { lock.unlock(); c.resume(returning: st) } else { waiters.append(c); lock.unlock() }
        }
    }

    // MARK: BREAK et lignes de contrôle

    /// Envoie un BREAK (≈ 0,25 s de niveau bas).
    @discardableResult
    public func sendBreak() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closing, fd >= 0 else { return false }
        return tcsendbreak(fd, 0) == 0
    }

    public enum ControlLine: Sendable { case dtr, rts }

    /// Positionne DTR ou RTS (`TIOCMBIS` / `TIOCMBIC`).
    @discardableResult
    public func setLine(_ line: ControlLine, high: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closing, fd >= 0 else { return false }
        var bit: Int32 = line == .dtr ? TIOCM_DTR : TIOCM_RTS
        return ioctl(fd, high ? UInt(TIOCMBIS) : UInt(TIOCMBIC), &bit) == 0
    }

    /// État courant des lignes de modem (`TIOCMGET`), `nil` si indisponible.
    public func modemBits() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard !closing, fd >= 0 else { return nil }
        var bits: Int32 = 0
        return ioctl(fd, UInt(TIOCMGET), &bits) == 0 ? bits : nil
    }

    public func isLineHigh(_ line: ControlLine) -> Bool? {
        guard let b = modemBits() else { return nil }
        return b & (line == .dtr ? TIOCM_DTR : TIOCM_RTS) != 0
    }

    /// Inverse DTR ou RTS ; rend le nouvel état, `nil` si l'opération a échoué.
    @discardableResult
    public func toggleLine(_ line: ControlLine) -> Bool? {
        let now = isLineHigh(line) ?? false
        return setLine(line, high: !now) ? !now : nil
    }
}
