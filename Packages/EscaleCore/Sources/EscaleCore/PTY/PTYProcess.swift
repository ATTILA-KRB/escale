import Foundation
import Darwin

/// Statut de fin d'un processus lancé dans un pty.
public enum PTYExitStatus: Equatable, Sendable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    /// Code de sortie si le processus s'est terminé normalement.
    public var exitCode: Int32? { if case .exited(let c) = self { return c } else { return nil } }

    public var description: String {
        switch self {
        case .exited(let c): "code \(c)"
        case .signaled(let s): "signal \(s)"
        }
    }
}

public struct PTYError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let errnoValue: Int32
    public var description: String { "\(operation) : \(String(cString: strerror(errnoValue)))" }
}

/// Processus fils exécuté dans un pseudo-terminal dont il est chef de session,
/// avec le pty comme terminal de contrôle (ssh lit les mots de passe sur /dev/tty,
/// le contrôle de tâches et Ctrl-C fonctionnent).
///
/// Technique : `forkpty` (libc) est appelable depuis Swift (`fork` seul ne l'est pas). Il fait
/// openpty + fork + setsid + TIOCSCTTY + dup2 0/1/2. Le fils ne fait ensuite que des appels
/// système préparés à l'avance (signaux par défaut, fermeture des fd hérités, chdir, execve).
/// Mesuré : `posix_spawn` + `POSIX_SPAWN_SETSID` + ouverture de l'esclave par file action
/// n'acquiert PAS le terminal de contrôle sous Darwin (ps : TTY « ?? », Ctrl-C sans effet),
/// d'où ce choix. Le parent ne garde que le maître.
///
/// Concurrence : tout l'état mutable est protégé par `queue` (lecture/fin) ou `lock`
/// (descripteur, statut) ; la classe est donc `@unchecked Sendable`.
/// L'instance se retient elle-même jusqu'à la fin du processus (sources GCD) : appeler
/// `terminate()`/`kill()` pour libérer un processus qui ne se termine pas seul.
public final class PTYProcess: @unchecked Sendable {
    /// Octets de sortie (stdout + stderr fusionnés par le pty). Se termine après la fin du
    /// processus et le vidage du tampon. Un seul consommateur.
    public let output: AsyncStream<Data>
    public let pid: pid_t
    /// Chemin du périphérique esclave (/dev/ttysNNN).
    public let slavePath: String

    private let continuation: AsyncStream<Data>.Continuation
    private let queue = DispatchQueue(label: "escale.pty.read")
    private let writeQueue = DispatchQueue(label: "escale.pty.write")
    private let lock = NSLock()

    // Protégé par `lock`
    private var master: Int32
    private var closed = false
    private var status: PTYExitStatus?
    private var waiters: [CheckedContinuation<PTYExitStatus, Never>] = []

    // Protégé par `queue`
    private var readSource: DispatchSourceRead?
    private var sourceCancelled = false
    private var exitStatusRaw: PTYExitStatus?

    /// Lance `executable` avec `arguments` (argv[0] = `argv0` ou l'exécutable) et `environment`
    /// (remplace tout l'environnement). Lève si le pty ou le lancement échouent.
    public init(
        executable: String,
        arguments: [String] = [],
        argv0: String? = nil,
        environment: [String: String],
        columns: Int,
        rows: Int,
        currentDirectory: String? = nil
    ) throws {
        // Vérification préalable : après fork on ne peut plus remonter d'erreur proprement.
        guard access(executable, X_OK) == 0 else { throw PTYError(operation: "accès à \(executable)", errnoValue: errno) }

        // Tout ce que le fils utilise est préparé AVANT le fork : entre fork et execve il ne
        // fait que des appels système (async-signal-safe), sans allocation ni comptage de références.
        let cExec = strdup(executable)!
        let cArgs = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 2)
        for (i, a) in ([argv0 ?? executable] + arguments).enumerated() { cArgs[i] = strdup(a) }
        cArgs[arguments.count + 1] = nil
        let envList = environment.map { "\($0.key)=\($0.value)" }
        let cEnv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: envList.count + 1)
        for (i, e) in envList.enumerated() { cEnv[i] = strdup(e) }
        cEnv[envList.count] = nil
        let cCwd: UnsafeMutablePointer<CChar>? = currentDirectory.map { strdup($0) }
        // Plafond des descripteurs à fermer dans le fils. L'inventaire se fait APRÈS le fork, dans le fils : un fd ouvert par
        // un autre thread entre un inventaire préalable et le fork serait sinon hérité (course). `closefrom` n'existe pas
        // sous Darwin ; fermer toute la plage 3..<limite (close sur un fd fermé = EBADF, sans effet) est sûr et rapide.
        let maxFD = Int32(min(max(getdtablesize(), 256), 65536))
        var dfl = sigaction()
        dfl.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&dfl.sa_mask)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        defer {
            free(cExec); for i in 0...arguments.count { free(cArgs[i]) }; cArgs.deallocate()
            for i in 0..<envList.count { free(cEnv[i]) }; cEnv.deallocate()
            free(cCwd)
        }

        var ws = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        var nameBuf = [CChar](repeating: 0, count: 128)
        var masterFD: Int32 = -1
        // forkpty : openpty + fork + setsid + TIOCSCTTY (terminal de contrôle) + dup2 0/1/2 côté fils.
        let childPid = forkpty(&masterFD, &nameBuf, nil, &ws)
        if childPid < 0 { throw PTYError(operation: "forkpty", errnoValue: errno) }
        if childPid == 0 {
            var n: Int32 = 1
            while n < NSIG { if n != SIGKILL && n != SIGSTOP { _ = sigaction(n, &dfl, nil) }; n += 1 }
            _ = sigprocmask(SIG_SETMASK, &emptyMask, nil)
            var f: Int32 = 3
            while f < maxFD { _ = close(f); f += 1 }
            if let cCwd, chdir(cCwd) != 0 { _exit(126) }
            _ = execve(cExec, cArgs, cEnv)
            _exit(127)
        }
        let fd = masterFD
        let path = String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        // IUTF8 : l'effacement de caractère gère les multi-octets.
        var tio = termios()
        if tcgetattr(fd, &tio) == 0 { tio.c_iflag |= tcflag_t(IUTF8); _ = tcsetattr(fd, TCSANOW, &tio) }

        self.master = fd
        self.pid = childPid
        self.slavePath = path
        var cont: AsyncStream<Data>.Continuation!
        self.output = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
        startReading(fd: fd)
        startReaper()
    }

    // MARK: - Lecture

    private func startReading(fd: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource = src
        src.setEventHandler { [self] in
            if !drain(fd: fd) { src.cancel() }
        }
        src.setCancelHandler { [self] in
            sourceCancelled = true
            tryFinish()
        }
        src.resume()
    }

    /// Lit tout ce qui est disponible. Renvoie false à la fin du flux (EOF/EIO).
    private func drain(fd: Int32) -> Bool {
        var buf = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<32 {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                continuation.yield(Data(buf[0..<n]))
            } else if n == 0 {
                return false
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return true
            } else if errno == EINTR {
                continue
            } else {
                return false // EIO : plus aucun détenteur de l'esclave
            }
        }
        return true
    }

    /// Thread dédié : waitpid bloquant (pas de zombie), puis vidage final et fermeture.
    private func startReaper() {
        let pid = self.pid
        let t = Thread { [self] in
            var raw: Int32 = 0
            var r: pid_t
            repeat { r = waitpid(pid, &raw, 0) } while r < 0 && errno == EINTR
            let s = raw & 0x7f
            let st: PTYExitStatus = r < 0 ? .exited(-1) : (s == 0 ? .exited((raw >> 8) & 0xff) : .signaled(s))
            queue.async { [self] in
                exitStatusRaw = st
                if !sourceCancelled { _ = drain(fd: masterFD()); readSource?.cancel() }
                tryFinish()
            }
        }
        t.name = "escale.pty.reaper"
        t.start()
    }

    private func masterFD() -> Int32 { lock.lock(); defer { lock.unlock() }; return master }

    /// Sur `queue` : termine quand le processus est fini ET que la source est annulée.
    private func tryFinish() {
        guard let st = exitStatusRaw, sourceCancelled else { return }
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let fd = master
        master = -1
        lock.unlock()
        Darwin.close(fd)
        readSource = nil
        continuation.finish()
        lock.lock()
        status = st
        let ws = waiters
        waiters = []
        lock.unlock()
        ws.forEach { $0.resume(returning: st) }
    }

    // MARK: - API

    /// Attend la fin du processus. Quand elle rend la main, le flux `output` est terminé,
    /// le maître est fermé et le fils est réapé.
    public func waitForExit() async -> PTYExitStatus {
        await withCheckedContinuation { (c: CheckedContinuation<PTYExitStatus, Never>) in
            lock.lock()
            if let st = status { lock.unlock(); c.resume(returning: st) } else { waiters.append(c); lock.unlock() }
        }
    }

    /// Statut si le processus est déjà terminé.
    public var exitStatus: PTYExitStatus? { lock.lock(); defer { lock.unlock() }; return status }

    /// Écrit des octets dans le pty (comme une saisie clavier). Sans effet après la fin.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { [self] in
            var offset = 0
            let bytes = [UInt8](data)
            while offset < bytes.count {
                lock.lock()
                if closed { lock.unlock(); return }
                let n = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress! + offset, bytes.count - offset) }
                let err = errno
                let fd = master
                lock.unlock()
                if n > 0 { offset += n; continue }
                if n < 0 && err == EINTR { continue }
                if n < 0 && (err == EAGAIN || err == EWOULDBLOCK) {
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 100)
                    continue
                }
                return
            }
        }
    }

    /// Change la taille du pty (TIOCSWINSZ ; le noyau envoie SIGWINCH au groupe de premier plan).
    public func resize(columns: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        var ws = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &ws)
    }

    /// Demande l'arrêt poliment : SIGTERM au groupe de processus du fils (chef de session).
    /// Un shell interactif ignore SIGTERM ; utiliser `kill()` en dernier recours.
    public func terminate() { signalGroup(SIGTERM) }

    /// SIGKILL au groupe de processus du fils.
    public func kill() { signalGroup(SIGKILL) }

    private func signalGroup(_ sig: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard status == nil else { return } // déjà réapé : le pid pourrait être réutilisé
        if killpg(pid, sig) != 0 { _ = Darwin.kill(pid, sig) }
    }
}
