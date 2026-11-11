# Spike FreeRDP 3 : moteur RDP embarque dans Escale

Date : 2026-11-11. Version evaluee : **FreeRDP 3.33.1** (tag officiel, publie le 2026-11-10).
Archive `https://github.com/FreeRDP/FreeRDP/archive/refs/tags/3.33.1.tar.gz`,
SHA-256 `6b6da1e7217f924b033da6896e70eb4c4a447c3900d03c0d10179062f0a7d495`.
Aucun fichier de l'app ni du coeur n'a ete touche : tout est dans `spikes/freerdp/`.

## Recommandation : **plus tard** (ne pas integrer maintenant)

- Faisabilite technique : **prouvee** (build universel, NLA, bitmaps GDI, entree souris, PNG).
- Obstacle : la **charge de securite** (338 avis de securite publies, dont 140 depuis septembre 2026, voir §4)
  et un cout estime de **~20 jours** pour une vue RDP de qualite (§5). Le client Microsoft externe couvre le besoin
  pour zero maintenance.
- Si on integre un jour : ne jamais charger FreeRDP dans le processus principal. Le mettre dans un **helper XPC / app
  separee** (comme `EscaleX11.app`), sans acces Keychain direct, avec le mot de passe transmis a la demande.

## 1. Licence et dependances

| Composant | Licence | Dans le binaire ? |
|---|---|---|
| FreeRDP / WinPR 3.33.1 | Apache-2.0 (`LICENSE`, README : « released under the Apache license ») | oui |
| OpenSSL 3.5.9 (LTS) | Apache-2.0 | oui, **statique** (`libssl.a`, `libcrypto.a`) |
| zlib | zlib | non embarque : `/usr/lib/libz.1.dylib` du systeme |
| cJSON / json-c | MIT | **desactives** (`-DWITH_JSON_DISABLED=ON`) ; sinon CMake accroche le dylib Homebrew `json-c` |
| ffmpeg, opus, cairo, libusb, CUPS, X11, Wayland, pcsc, krb5 | LGPL/GPL selon cas | **exclus** |
| MD4 (Solar Designer), md5, quelques en-tetes WinPR | domaine public / BSD | oui (copies dans le source ; conserver les mentions) |

`rg` sur le source : aucune licence GPL/LGPL ; les occurrences de « GPL » sont des faux positifs (`cgplane`, `PLUGPLAY`).
Frameworks systeme lies : VideoToolbox, CoreMedia, CoreVideo, CoreFoundation, Foundation, Security, SystemConfiguration,
IOKit, AppKit, Carbon, CoreServices. **Aucune dependance Homebrew a l'execution** (`otool -L` : uniquement `/usr/lib` et `/System`).
Compatibilite distribution payante Developer ID : oui (Apache-2.0 permissive). Obligations : joindre le texte de la licence
Apache-2.0 (FreeRDP et OpenSSL) et les mentions dans les « Licences » de l'app. Sans ffmpeg il n'y a pas de piege LGPL.

## 2. Construction (commandes reellement executees)

Scripts reproductibles dans ce dossier (les noms d'options sont ceux de 3.33.1) :

```
spikes/freerdp/build-openssl.sh   # OpenSSL 3.5.9 statique arm64+x86_64, cible macOS 15.0   -> 70 s
spikes/freerdp/build-freerdp.sh   # FreeRDP 3.33.1 statique universel                        -> 44 s
ARCH=arm64  spikes/freerdp/build-rdpshot.sh ; ARCH=x86_64 spikes/freerdp/build-rdpshot.sh
```

- Machine : Mac arm64, 18 coeurs, macOS 27.0.1, Xcode (`DEVELOPER_DIR=/Applications/Xcode.app/...`). cmake 4 / ninja via
  `/opt/homebrew/bin` (hors PATH par defaut, ajoute dans le script). Homebrew n'est necessaire **qu'a la construction**.
- Options retenues : `BUILD_SHARED_LIBS=OFF`, `WITH_CLIENT_COMMON=ON`, `WITH_CLIENT=OFF` (pas de client X11/SDL),
  `WITH_X11/WAYLAND/FFMPEG/SWSCALE/CUPS/PULSE/ALSA/MACAUDIO/PCSC/KRB5/AAD/FUSE/OPENH264/CAIRO/JPEG/OPUS/LIBUSB=OFF`,
  `CHANNEL_URBDRC=OFF`, `WITH_JSON_DISABLED=ON`, `WITH_VERBOSE_WINPR_ASSERT=OFF`, `WITH_CCACHE=OFF` (temps honnetes),
  `CMAKE_OSX_DEPLOYMENT_TARGET=15.0`. `WITH_SERVER`/`WITH_SHADOW`/`WITH_SAMPLE=ON` **uniquement pour les tests** (a retirer en prod).
- Pieges rencontres : (1) CMake accroche en silence opus, cairo, libusb et json-c de Homebrew (erreur `opus/opus.h`, dylib
  `json-c` liee) : les desactiver explicitement ; (2) `pkg-config` pointe vers `openssl@4` : lier OpenSSL a la main ;
  (3) le bottle OpenSSL Homebrew est arm64 seul et vise macOS 27 (avertissements `built for newer macOS`) : il faut le compiler
  soi-meme pour un binaire universel cible 15.0 (script fourni). SHA-256 OpenSSL verifie contre le `.sha256` publie
  (`603f5602...eb859a`).
- Tailles : bibliotheques statiques universelles **19 Mo** (arm64+x86_64, LTO thin ; 11 Mo arm64 seul). Binaire de test lie
  statiquement, strip : **6,6 Mo arm64**, **7,3 Mo x86_64**, 13,9 Mo universel. Surcout attendu dans l'app : **~6 Mo par
  architecture, ~13 Mo en universel** (hors canaux supplementaires).
- Canaux statiques effectivement charges au runtime : `rdpgfx`, `disp`, `ainput`, `rdpsnd`, `drdynvc` (journal du prototype).

## 3. Prototype (`rdpshot.c`, ~330 lignes de C)

CLI : `rdpshot <hote> <port> <user|-> <mdp|-> <sortie.png> [secondes] [LxH] [nla|tls]`. Il cree un contexte
`freerdp_client_context_new`, regle `rdpSettings` par API (pas par ligne de commande), `gdi_init(PIXEL_FORMAT_BGRX32)` (32 bpp),
cadre les callbacks `BeginPaint/EndPaint/DesktopResize`, envoie des deplacements de souris (`freerdp_input_send_mouse_event`),
puis ecrit un PNG du `primary_buffer` (encodeur PNG minimal en zlib). Le certificat est accepte sans verification
(`IgnoreCertificate`) : **jetable, a ne pas reproduire** (l'app devra faire du TOFU, invariant 10).

Resultats reels :

| Test | Resultat |
|---|---|
| `sfreerdp-server` local (TLS, sans NLA), arm64 | `RESULT ok 1024x768 frames=22` ; l'icone dessinee par le serveur apparait a la position de la souris envoyee (entree + sortie de bout en bout). Capture : `capture-sample-server.png` |
| Idem binaire **x86_64** (Rosetta) | `RESULT ok 1024x768 frames=22` |
| `freerdp-shadow-cli` local, **NLA/NTLM**, mauvais mot de passe | `ERRCONNECT_LOGON_FAILURE 0x00020014` (cote serveur : `SEC_E_MESSAGE_ALTERED`, MIC invalide) |
| Idem, bon mot de passe | `RESULT ok 1512x982 frames=1` (capture reelle de l'ecran du Mac par ScreenCaptureKit ; **fichier supprime**, il montrait mon bureau) |
| Sans identifiants, mode TLS | le callback `AuthenticateEx` est appele avant la poignee de main ; refus => `ERRCONNECT_CONNECT_CANCELLED 0x0002000B` |

Reproduire : `python3 run-local-test.py`, `python3 run-shadow-test.py` (prerequis dans leurs en-tetes ; certificat de test :
`openssl req -x509 -newkey rsa:2048 -nodes -keyout server.key -out server.crt -subj /CN=spike.local`).

### PC Windows 192.168.1.10 : **non verifie**
Le PC est injoignable depuis ce Mac pendant tout le spike : `ping` 100 % de perte, `ssh rayan@192.168.1.10` expire
(`Operation timed out`, port 22), `nc -z -G 3 192.168.1.10 3389` renvoie 1, pas d'entree ARP (Mac sur 192.168.1.13).
Je n'ai donc pas pu lire `fDenyTSConnections` ni tester contre le vrai Windows (negociation NLA/CredSSP avec certificat
Windows, RDPGFX/H.264 reel). Rien n'a ete modifie sur ce PC. Les deux serveurs locaux valident la pile TLS/NLA/NTLM et les
codecs RemoteFX/NSCodec, pas les particularites de Windows (CredSSP + Kerberos/`TERMSRV`, Network Level Auth strict, GFX).

## 4. Points de l'app

- **Signature / notarisation** : le plus simple est la liaison statique (un seul binaire a signer, plus de dylib).
  Teste : binaire universel signe `codesign --force --options runtime --timestamp --sign <Developer ID>` ;
  `codesign --verify --strict` : « valid on disk, satisfies its Designated Requirement » ; drapeau `runtime` present ;
  `spctl` : « Unnotarized Developer ID » (attendu, **notarisation non lancee**). Aucun entitlement special n'est apparu
  necessaire pour le client (pas de JIT ni de dylib tierce). Si un helper XPC est choisi : meme chaine que `EscaleX11.app`.
- **Maintenance / CVE** : depot FreeRDP, avis GitHub dedoublonnes : **338 avis** (3 critiques, 65 hauts, 200 moyens, 70 bas) ;
  **140 publies depuis 2026-09** (64 en septembre, 63 en octobre, 13 en novembre jusqu'au 9) ; 82 concernent le client ou le
  GDI (ex. 2026-11-09 : « GDI OpaqueRect bounds integer overflow », UAF du cache de brosses). Versions : 3.31.0 le 08-26,
  3.32.0 le 09-23, 3.33.0 le 11-02, 3.33.1 le 11-10, soit une version tous les 7 a 30 jours. Un client RDP analyse des
  donnees d'un serveur potentiellement hostile, en C non sur : prevoir **une mise a jour d'Escale a chaque version
  mineure** (bump du SHA-256, rebuild, signature, notarisation, selftest) et un suivi des avis. Le sondage utilise l'API
  publique, sans authentification, pagination par curseur.
- **Effort pour une vue RDP integree** (estimation, en jours-personne, MVP sans audio ni redirection de lecteurs) :

| Lot | Jours |
|---|---|
| Integration du build : XcodeGen, cible C `CEscaleRDP` (module map), script de build epingle (SHA-256) | 1,5 |
| Session : thread de connexion, machine d'etats, `RDPSettings` -> `rdpSettings`, mapping d'erreurs, deconnexion propre | 3 |
| Rendu : `CALayer`/Metal depuis le tampon BGRX, rectangles invalides, Retina, mise a l'echelle | 3 |
| Clavier : table de scancodes (ISO/ANSI/AZERTY), modificateurs, raccourcis Cmd, IME | 3 |
| Souris, molette, formes de curseur distantes | 2 |
| Presse-papiers (`cliprdr`, texte d'abord ; fichiers/images en plus) | 3 |
| Redimensionnement dynamique (canal `disp`, anti-rebond) | 1,5 |
| NLA : mot de passe via Keychain apres connexion reussie (invariant 11), empreinte de certificat TOFU, cle modifiee refusee (invariant 10) | 2 |
| Recette `--selftest-rdp` (serveur d'exemple local en fixture), tests | 2 |
| Signature, notarisation, processus de mise a jour, licences | 1 |
| **Total** | **~21 j** (fourchette 18-28 selon IME/presse-papiers) |

  Le depot contient `client/Mac` (client Objective-C de reference) qui peut servir de modele pour clavier/presse-papiers,
  sans le reutiliser tel quel.
- **Comparaison avec le client Microsoft externe** (autre flux, `externalOpeners[.rdp]`) :

| Critere | FreeRDP integre | Client Microsoft (Windows App) externe |
|---|---|---|
| Cout initial | ~21 j | ~1-2 j (fichier `.rdp` genere, ouverture) |
| Maintenance / securite | a notre charge, 1 mise a jour/mois, surface C | par Microsoft |
| Compatibilite Windows (CredSSP, Kerberos, passerelle RD, H.264/AVC444, multi-ecran, USB, audio, RemoteApp) | partielle, a deboguer | complete |
| Integration (onglet dans la fenetre, tunnel SSH `-L` automatique) | oui | non (fenetre separee) ; le tunnel reste possible via `localhost:port` |
| Taille de l'app | +13 Mo | 0 (mais exige l'installation du client) |
| Dependance | aucune a l'execution | Windows App installee |

## 5. Risques

1. Securite : bug de memoire dans le processus de l'app qui detient les cles et mots de passe => isoler dans un helper.
2. Rythme de correctifs : un retard de quelques semaines laisse des CVE hautes connues dans une app payante.
3. Compatibilite reelle avec le Windows de Rayan **non testee** (PC injoignable).
4. Clavier macOS -> scancodes RDP, IME, dispositions non US : la partie la plus longue a polir.
5. OpenSSL a maintenir aussi (cadence propre) ; solution alternative non evaluee : `WITH_MBEDTLS`.
6. H.264 (VideoToolbox lie mais ffmpeg exclu) non teste ; sans lui, RemoteFX/bitmaps suffisent a faible debit mais le fluide
   haute resolution est moindre.

## Entree proposee pour `docs/PLAN.md`

### RDP integre (FreeRDP) : reporte
Spike du 2026-11-11 (`spikes/freerdp/REPORT.md`) : FreeRDP 3.33.1 (Apache-2.0) compile en statique universel (OpenSSL 3.5.9 interne,
sans Homebrew a l'execution), NLA/TLS et bitmaps GDI valides contre les serveurs d'exemple de FreeRDP (arm64 et x86_64), signature
hardened runtime verifiee. Decision : ne pas integrer en V1 ; RDP passe par le client externe. Raisons : ~21 j de travail, ~13 Mo,
338 avis de securite (140 en 10 semaines). Reconsiderer avec un helper XPC isole si la demande d'un RDP integre se confirme.
Non verifie : le PC Windows de test etait injoignable.

## Invariant propose pour `AGENTS.md` (seulement si integration decidee)
15. FreeRDP (si integre) : liaison statique dans un helper separe (`Contents/Helpers/EscaleRDP.app`), version et SHA-256 epingles
    (`spikes`/`scripts/rdp-bundle.sh`), OpenSSL compile par le script (jamais celui de Homebrew), jamais de `IgnoreCertificate` :
    empreinte de certificat memorisee a la premiere connexion, changement refuse (invariant 10), mot de passe lu dans le Keychain
    et transmis au helper sans passer par un fichier ni un argument de ligne de commande.
