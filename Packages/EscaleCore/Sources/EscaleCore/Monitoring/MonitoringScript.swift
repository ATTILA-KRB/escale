import Foundation

/// Script POSIX sh envoyé en argument à `ssh` (aucun fichier déposé côté serveur) : une boucle qui émet un bloc
/// balisé toutes les 2 s, tant que la sortie standard est ouverte (la fin de ssh coupe la boucle par SIGPIPE).
///
/// Format d'un bloc (lignes `clé=valeur`) :
/// ```
/// @@ESC begin
/// os=Linux
/// load=0.52                     charge sur 1 minute
/// cpu=<total> <inactif>         compteurs cumulés de /proc/stat (Linux) …
/// cpupct=12.5                   … ou pourcentage direct (macOS : somme de %cpu de ps / nombre de cœurs)
/// mem=<total> <utilisé>         octets
/// disk=<total> <utilisé> <n>%   octets de « / » et pourcentage rapporté par df
/// net=<interface> <rx> <tx>     octets cumulés, une ligne par interface
/// users=<n>
/// uptime=<secondes>
/// @@ESC end
/// ```
/// Un système inconnu répond `@@ESC unsupported <uname>` puis le script se termine.
/// Linux d'abord (`/proc`) ; repli macOS (`sysctl`, `vm_stat`, `netstat -ibn`).
/// Variables de test (sans effet en service) : `ESC_PROC` (racine de /proc), `ESC_OS` (remplace `uname -s`),
/// `ESC_ONCE` (un seul bloc).
public enum MonitoringScript {
    public static let interval = 2

    public static let body = #"""
    P=${ESC_PROC:-/proc}
    os=${ESC_OS:-$(uname -s 2>/dev/null)}
    case "$os" in Linux|Darwin) ;; *) echo "@@ESC unsupported $os"; exit 0;; esac
    while :; do
    echo "@@ESC begin"
    echo "os=$os"
    if [ "$os" = Linux ]; then
    read l _ < "$P/loadavg" && echo "load=$l"
    awk '/^cpu /{printf "cpu=%.0f %.0f\n", $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' "$P/stat"
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2} END{if(a=="")a=f+b+c; printf "mem=%.0f %.0f\n", t*1024, (t-a)*1024}' "$P/meminfo"
    awk 'NR>2{sub(/^ +/,""); i=index($0,":"); n=substr($0,1,i-1); split(substr($0,i+1),f," "); printf "net=%s %.0f %.0f\n", n, f[1], f[9]}' "$P/net/dev"
    read u _ < "$P/uptime" && echo "uptime=$u"
    else
    sysctl -n vm.loadavg | awk '{print "load=" $2}'
    ps -A -o %cpu= | awk -v n="$(sysctl -n hw.ncpu)" '{s+=$1} END{printf "cpupct=%.1f\n", s/n}'
    vm_stat | awk -v t="$(sysctl -n hw.memsize)" '/page size of/{ps=$8} /^Pages active/{a=$3+0} /^Pages wired down/{w=$4+0} /^Pages occupied by compressor/{c=$5+0} END{printf "mem=%.0f %.0f\n", t, (a+w+c)*ps}'
    netstat -ibn | awk '$3 ~ /^<Link/ {n=$1; sub(/\*$/,"",n); printf "net=%s %.0f %.0f\n", n, $(NF-4), $(NF-1)}'
    sysctl -n kern.boottime | awk -v now="$(date +%s)" '{gsub(/,/,""); print "uptime=" now-$4}'
    fi
    df -Pk / | awk 'NR==2{printf "disk=%.0f %.0f %s\n", $2*1024, $3*1024, $5}'
    echo "users=$(who | wc -l | tr -d ' ')"
    echo "@@ESC end"
    [ -n "$ESC_ONCE" ] && exit 0
    sleep 2
    done
    """#

    /// Commande distante : le script est passé à `sh -c` entre apostrophes (les apostrophes du script sont
    /// protégées), de sorte que le shell de connexion distant (bash, zsh, dash…) le transmet tel quel.
    public static func remoteCommand() -> String {
        "exec sh -c '" + body.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
