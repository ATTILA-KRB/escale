import Foundation

/// Quoting POSIX strict pour les commandes distantes. Les chemins ne sont JAMAIS collés dans un script : ils passent
/// en arguments positionnels (`sh -c SCRIPT sh ARG…`), chacun entre apostrophes.
public enum ShellQuote {
    /// Mot protégé par des apostrophes ; une apostrophe devient `'\''`. Tout autre caractère (espace, `$`, `` ` ``,
    /// retour à la ligne, `*`, `;`…) est littéral entre apostrophes.
    public static func word(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Préfixe interne d'un argument « octets » (nom non UTF-8) : `command` le décode côté serveur. Le contrôle U+0001 ne
    /// figure jamais dans un chemin ordinaire ; si c'était le cas, `path` passe quand même par l'encodage (pas d'ambiguïté).
    static let rawMarker = "\u{1}octets:"

    /// Chemin prêt à servir d'argument. Un chemin UTF-8 reste du texte ; un nom non UTF-8 (octets invalides) est encodé en
    /// `\ooo` octal derrière `rawMarker`, car un argument de ligne de commande ssh est une chaîne et ne sait pas porter
    /// ces octets. Seul un NUL est refusé (inexprimable dans un chemin POSIX).
    static func path(_ d: Data) throws -> String {
        guard !d.contains(0) else {
            throw SFTPError.status(.opUnsupported, message: "nom contenant un octet nul non pris en charge en mode shell")
        }
        if let s = String(data: d, encoding: .utf8), !s.hasPrefix(rawMarker) { return s }
        return rawMarker + escaped(d)
    }

    /// Octets en ASCII sûr : tout sauf `[A-Za-z0-9/._]` devient `\ooo` (le tiret aussi : jamais pris pour une option par
    /// `printf`, `%` et `\` non plus).
    static func escaped(_ d: Data) -> String {
        var out = ""
        for b in d {
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "/"), UInt8(ascii: "."), UInt8(ascii: "_"):
                out.unicodeScalars.append(Unicode.Scalar(b))
            default:
                let o = String(b, radix: 8)
                out += "\\" + String(repeating: "0", count: 3 - o.count) + o
            }
        }
        return out
    }

    /// Retour des arguments encodés : `printf` (format = l'argument) restitue les octets ; un `x` ajouté puis retiré
    /// protège les retours à la ligne finaux que `$(...)` supprimerait. Constant, ajouté seulement si un argument en a besoin.
    static let decodePrelude = #"""
    n=$#
    while [ "$n" -gt 0 ]; do a=$1; shift; d=$(printf "$a"; printf x); set -- "$@" "${d%x}"; n=$((n-1)); done

    """#

    /// `env LC_ALL=C /bin/sh -c '<script>' sh '<arg1>' …` : `env` (et non `LC_ALL=C cmd`) pour rester valable quel que soit
    /// le shell de connexion distant (csh, fish…). Le script est constant, seuls les arguments varient.
    static func command(script: String, args: [String]) -> String {
        var script = script
        var args = args
        if args.contains(where: { $0.hasPrefix(rawMarker) }) {
            // Au moins un nom en octets : tous les arguments passent en ASCII échappé, décodés par le prélude.
            args = args.map { $0.hasPrefix(rawMarker) ? String($0.dropFirst(rawMarker.count)) : escaped(Data($0.utf8)) }
            script = decodePrelude + script
        }
        return (["env", "LC_ALL=C", "/bin/sh", "-c", word(script), "sh"] + args.map(word)).joined(separator: " ")
    }
}

/// Façon de lister un dossier, de la plus fidèle à la plus tolérante.
public enum ShellListingTier: Sendable, Equatable, CaseIterable {
    /// `find -maxdepth 1 -printf` (GNU findutils) : noms exacts, dates exactes, un seul processus.
    case gnuFind
    /// Boucle POSIX + `stat` (BSD/macOS `stat -f`, GNU/busybox `stat -c`) : mêmes garanties, un `stat` pour tout le dossier.
    case statLoop
    /// `ls -lan` (avec `--time-style=+%s` si disponible) : dernier recours, noms avec retour à la ligne non pris en charge.
    case ls
}

/// Un élément décrit par une commande de listage, avant conversion en `SFTPDirectoryEntry`.
struct ShellRecord: Equatable {
    var type: Character      // d, f, l, o
    var size: UInt64
    var mtime: Double
    var permissions: UInt32  // bits rwx seuls
    var link: String
    var name: Data

    var entry: SFTPDirectoryEntry {
        let typeBits: UInt32 = switch type { case "d": 0o040000; case "f": 0o100000; case "l": 0o120000; default: 0o010000 }
        return SFTPDirectoryEntry(nameBytes: name, attributes: SFTPAttributes(
            size: size, permissions: typeBits | permissions, modificationTime: Date(timeIntervalSince1970: mtime)))
    }
}

enum ShellScripts {
    static let checkDirectory = """
    d=$1
    [ -e "$d" ] || { echo 'No such file or directory' >&2; exit 1; }
    [ -d "$d" ] || { echo 'Not a directory' >&2; exit 1; }
    [ -r "$d" ] && [ -x "$d" ] || { echo 'Permission denied' >&2; exit 1; }

    """

    static let checkPath = """
    p=$1
    case $p in /*) ;; *) p=./$p ;; esac
    [ -e "$p" ] || [ -L "$p" ] || { echo 'No such file or directory' >&2; exit 1; }
    [ "$2" = 1 ] && [ ! -e "$p" ] && { echo 'No such file or directory' >&2; exit 1; }

    """

    static let findFormat = #"'%y\0%s\0%T@\0%m\0%l\0%f\0'"#

    static let listGNUFind = checkDirectory + "exec find \"$d\" -mindepth 1 -maxdepth 1 -printf \(findFormat)\n"

    static let statGNUFind = checkPath
        + "if [ \"$2\" = 1 ]; then exec find -L \"$p\" -maxdepth 0 -printf \(findFormat); "
        + "else exec find \"$p\" -maxdepth 0 -printf \(findFormat); fi\n"

    /// Du premier `stat` aux enregistrements `type NUL « mode taille mtime » NUL cible NUL nom NUL`.
    /// `$SL` vaut `-L` pour suivre les liens ; `$@` porte les noms.
    static let statTail = #"""
    if stat -c %a / >/dev/null 2>&1; then
      stat $SL -c '%a %s %Y' -- "$@"
    else
      stat $SL -f '%Lp %z %m' -- "$@"
    fi | {
      for f; do
        read -r i || i='0 0 0'
        if [ -z "$SL" ] && [ -L "$f" ]; then t=l; l=$(readlink -- "$f")
        elif [ -d "$f" ]; then t=d; l=
        elif [ -f "$f" ]; then t=f; l=
        else t=o; l=; fi
        printf '%s\0%s\0%s\0%s\0' "$t" "$i" "$l" "$f"
      done
    }

    """#

    static let listStatLoop = checkDirectory + #"""
    cd -- "$d" || exit 1
    SL=
    set --
    for f in .[!.]* ..?* *; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      set -- "$@" "$f"
    done
    [ $# -gt 0 ] || exit 0

    """# + statTail

    static let statStatLoop = checkPath + """
    SL=; [ "$2" = 1 ] && SL=-L
    set -- "$p"

    """ + statTail

    static let listLs = checkDirectory + """
    cd -- "$d" || exit 1
    ls -lan --time-style=+%s 2>/dev/null || ls -lan

    """

    static let statLs = checkPath + """
    if [ "$2" = 1 ]; then o=-lndL; else o=-lnd; fi
    ls $o --time-style=+%s -- "$p" 2>/dev/null || ls $o -- "$p"

    """

    static func list(_ tier: ShellListingTier) -> String {
        switch tier { case .gnuFind: listGNUFind; case .statLoop: listStatLoop; case .ls: listLs }
    }
    static func stat(_ tier: ShellListingTier) -> String {
        switch tier { case .gnuFind: statGNUFind; case .statLoop: statStatLoop; case .ls: statLs }
    }

    static let realpath = #"""
    p=$1
    if [ -d "$p" ]; then
      cd -- "$p" 2>/dev/null && pwd -P || { echo 'Permission denied' >&2; exit 1; }
      exit
    fi
    case $p in /*) ;; *) p=./$p ;; esac
    dir=${p%/*}; base=${p##*/}
    [ -n "$dir" ] || dir=/
    [ -d "$dir" ] || { echo 'No such file or directory' >&2; exit 1; }
    d=$(cd -- "$dir" 2>/dev/null && pwd -P) || { echo 'Permission denied' >&2; exit 1; }
    case $d in /) printf '/%s' "$base" ;; *) printf '%s/%s' "$d" "$base" ;; esac

    """#

    static let makeDirectory = "exec mkdir -- \"$1\"\n"
    static let removeDirectory = "exec rmdir -- \"$1\"\n"
    static let removeFile = "exec rm -- \"$1\"\n"

    /// Une destination dossier existante ferait entrer `mv` DANS ce dossier : on refuse plutôt que de déplacer ailleurs.
    static let rename = """
    if [ -d "$2" ] && [ ! -L "$2" ]; then echo 'Is a directory' >&2; exit 1; fi
    exec mv -f -- "$1" "$2"

    """

    static let copy = """
    if [ -e "$2" ] || [ -L "$2" ]; then echo 'File exists' >&2; exit 1; fi
    exec cp -a -- "$1" "$2"

    """

    /// Téléchargement : `dd` par blocs de 64 Kio à partir du bloc `$2` (reprise alignée sur 64 Kio).
    static let download = """
    p=$1
    [ -e "$p" ] || { echo 'No such file or directory' >&2; exit 1; }
    [ -f "$p" ] || { echo 'Not a regular file' >&2; exit 1; }
    [ -r "$p" ] || { echo 'Permission denied' >&2; exit 1; }
    exec dd if="$p" bs=65536 skip="$2" 2>/dev/null

    """

    /// Lecture d'une plage : blocs de 4 Kio (le découpage fin se fait côté client).
    static let readBlock = """
    p=$1
    [ -f "$p" ] || { echo 'No such file or directory' >&2; exit 1; }
    [ -r "$p" ] || { echo 'Permission denied' >&2; exit 1; }
    exec dd if="$p" bs=4096 skip="$2" count="$3" 2>/dev/null

    """

    /// Envoi : écrit dans `<fichier>.part` (créé, ou prolongé si `$2` = append) ; `mv` n'a lieu qu'après vérification.
    static let upload = """
    p=$1
    if [ -d "$p" ] && [ ! -L "$p" ]; then echo 'Is a directory' >&2; exit 1; fi
    if [ "$2" = append ]; then exec cat >> "$p.part"; else exec cat > "$p.part"; fi

    """

    static let finishUpload = """
    p=$1
    if [ -d "$p" ] && [ ! -L "$p" ]; then echo 'Is a directory' >&2; exit 1; fi
    chmod "$2" "$p.part" && mv -f "$p.part" "$p"

    """

    static let writeBlockTruncate = "exec cat > \"$1\"\n"
    /// Écriture à un offset. Aligné sur 4 Kio : `dd` par blocs de 4 Kio (un octet par appel système, `bs=1`, rendait un bloc
    /// de 1 Mio interminable) ; une lecture courte du tube est écrite telle quelle à la suite, `seek` ne vaut que pour le départ.
    static let writeBlockAt = """
    if [ $(($2 % 4096)) -eq 0 ]; then exec dd of="$1" bs=4096 seek=$(($2 / 4096)) conv=notrunc 2>/dev/null; fi
    exec dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null

    """
}

enum ShellParsers {
    /// Découpe en champs séparés par NUL (octets exacts, pas de décodage).
    static func fields(_ bytes: Data) -> [Data] {
        var out: [Data] = []
        var cur = Data()
        for b in bytes { if b == 0 { out.append(cur); cur = Data() } else { cur.append(b) } }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
    static func fields(_ text: String) -> [Data] { fields(Data(text.utf8)) }

    static func gnuFind(_ stdout: String) throws -> [ShellRecord] { try gnuFind(Data(stdout.utf8)) }
    static func statLoop(_ stdout: String) throws -> [ShellRecord] { try statLoop(Data(stdout.utf8)) }
    static func ls(_ stdout: String, now: Date = Date()) -> [ShellRecord] { ls(Data(stdout.utf8), now: now) }

    static func gnuFind(_ stdout: Data) throws -> [ShellRecord] {
        let f = fields(stdout)
        guard f.count % 6 == 0 else { throw SFTPError.protocolViolation("listage find incohérent (\(f.count) champs)") }
        var out: [ShellRecord] = []
        var i = 0
        while i < f.count {
            let t = String(decoding: f[i], as: UTF8.self)
            let type: Character = switch t { case "d": "d"; case "f": "f"; case "l": "l"; default: "o" }
            out.append(ShellRecord(
                type: type, size: UInt64(String(decoding: f[i + 1], as: UTF8.self)) ?? 0,
                mtime: Double(String(decoding: f[i + 2], as: UTF8.self)) ?? 0,
                permissions: UInt32(String(decoding: f[i + 3], as: UTF8.self), radix: 8) ?? 0,
                link: String(decoding: f[i + 4], as: UTF8.self), name: f[i + 5]))
            i += 6
        }
        return out
    }

    static func statLoop(_ stdout: Data) throws -> [ShellRecord] {
        let f = fields(stdout)
        guard f.count % 4 == 0 else { throw SFTPError.protocolViolation("listage stat incohérent (\(f.count) champs)") }
        var out: [ShellRecord] = []
        var i = 0
        while i < f.count {
            let t = String(decoding: f[i], as: UTF8.self)
            let nums = String(decoding: f[i + 1], as: UTF8.self).split(separator: " ")
            out.append(ShellRecord(
                type: t.first ?? "o", size: nums.count > 1 ? UInt64(nums[1]) ?? 0 : 0,
                mtime: nums.count > 2 ? Double(nums[2]) ?? 0 : 0,
                permissions: nums.first.flatMap { UInt32($0, radix: 8) } ?? 0,
                link: String(decoding: f[i + 2], as: UTF8.self), name: f[i + 3]))
            i += 4
        }
        return out
    }

    /// Sortie de `ls -lan` (avec ou sans `--time-style=+%s`). Les noms avec retour à la ligne ne sont pas gérés.
    /// Décodée en Latin-1 (un octet = un caractère, sans perte) : les champs sont ASCII et le nom retrouve ses octets exacts.
    static func ls(_ stdout: Data, now: Date = Date()) -> [ShellRecord] {
        var out: [ShellRecord] = []
        var text = ""
        text.unicodeScalars.append(contentsOf: stdout.map { Unicode.Scalar($0) })
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first, "-dlcbps".contains(first), !line.hasPrefix("total ") else { continue }
            var tokens: [Substring] = []
            var rest = Substring(line)
            func next() -> Substring? {
                rest = rest.drop(while: { $0 == " " })
                guard !rest.isEmpty else { return nil }
                let end = rest.firstIndex(of: " ") ?? rest.endIndex
                let t = rest[rest.startIndex..<end]
                rest = rest[end...]
                return t
            }
            guard let mode = next(), mode.count >= 10 else { continue }
            tokens.append(mode)
            _ = next(); _ = next(); _ = next()          // liens, uid, gid
            guard var sizeToken = next() else { continue }
            if "cb".contains(first) { sizeToken = next() ?? sizeToken } // « major, minor »
            guard let d1 = next() else { continue }
            var mtime = 0.0
            if let epoch = Double(d1), d1.count >= 9 {
                mtime = epoch
            } else {
                guard let day = next(), let tm = next() else { continue }
                mtime = lsDate(month: String(d1), day: String(day), timeOrYear: String(tm), now: now)
            }
            var name = String(rest.drop(while: { $0 == " " }))
            var link = ""
            if first == "l", let r = name.range(of: " -> ") {
                link = String(name[r.upperBound...]); name = String(name[..<r.lowerBound])
            }
            if name == "." || name == ".." || name.isEmpty { continue }
            let type: Character = switch first { case "d": "d"; case "-": "f"; case "l": "l"; default: "o" }
            out.append(ShellRecord(type: type, size: UInt64(sizeToken) ?? 0, mtime: mtime,
                                   permissions: lsPermissions(String(mode)), link: link, name: Data(name.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })))
        }
        return out
    }

    static func lsPermissions(_ mode: String) -> UInt32 {
        let c = Array(mode.dropFirst().prefix(9))
        guard c.count == 9 else { return 0 }
        var bits: UInt32 = 0
        for (i, ch) in c.enumerated() {
            let shift = UInt32(8 - i)
            let on: Bool
            switch ch { case "-", "S", "T": on = false; default: on = true }
            if on { bits |= 1 << shift }
        }
        return bits
    }

    private static func lsDate(month: String, day: String, timeOrYear: String, now: Date) -> Double {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard let m = months.firstIndex(of: month), let d = Int(day) else { return 0 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        var comps = DateComponents(); comps.month = m + 1; comps.day = d
        if timeOrYear.contains(":") {
            let hm = timeOrYear.split(separator: ":").compactMap { Int($0) }
            comps.hour = hm.first; comps.minute = hm.count > 1 ? hm[1] : 0
            comps.year = cal.component(.year, from: now)
            if let date = cal.date(from: comps), date.timeIntervalSince(now) > 86_400 {
                comps.year = (comps.year ?? 0) - 1
            }
        } else {
            comps.year = Int(timeOrYear)
        }
        return cal.date(from: comps)?.timeIntervalSince1970 ?? 0
    }
}
