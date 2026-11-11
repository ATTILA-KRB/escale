# Plan — client SSH macOS « à la MobaXterm » (Swift)

Date : 2026-11-10. Statut : D1 tranché (feuille blanche), spikes S1 et S2 faits le 2026-11-10 (§8). Aucun code de production écrit.

## 1. État des lieux (vérifié)

- `~/Documents/Quay` = clone de `babul/quay` (MIT, v0.7.1, dernier commit 2026-10-10), branche locale `rayan/improvements`
  (1 fichier modifié, `IDEA.md` = « APP SSH en full swift »). 12 820 lignes Swift app + 4 914 lignes de tests.
- Quay couvre déjà : onglets, barre latérale dossiers/recherche floue, import `~/.ssh/config`, secrets Keychain + askpass,
  superviseur de session (reconnexion sans perdre l'écran), snippets, scripts de login, export chiffré, Sparkle, notarisation.
- Quay ne couvre pas : navigateur SFTP graphique (il lance `sftp`/`lftp` en CLI dans un onglet), gestionnaire de tunnels,
  multi-exécution, panneaux scindés, X11, RDP/VNC/série, édition de fichier distant.
- Quay n'est pas « full Swift » : terminal = libghostty (Zig/C, xcframework compilé via zig@0.16), SSH = `/usr/bin/ssh`.

## 2. Recensement concurrence (sources consultées le 2026-11-10)

| Produit | Couverture | Prix | Techno |
|---|---|---|---|
| Royal TSX | SSH, Telnet, série, RDP, VNC, transfert, X11 fwd, tunnels | Lite gratuit (10 connexions), 49 EUR licence | natif |
| Termius | SSH, Mosh, Telnet, série, SFTP, tunnels, broadcast | Starter gratuit, Pro 10 USD/mois (annuel) | Electron |
| SecureCRT | SSH, Telnet, série, SFTP, X11 fwd, scripting | 119 USD | natif |
| Tabby / Electerm | SSH, SFTP à côté, série, tunnels, X11 fwd (Electerm : RDP/VNC) | gratuit MIT | Electron |
| Upshell | SSH, SFTP à côté même connexion, tunnels L/R/SOCKS5, 8 bastions, panneaux, « type in all panes », enregistrement | gratuit + achats intégrés | Swift + SwiftNIO, sandbox MAS |
| Tamio | terminal Ghostty, SFTP double panneau, statut serveurs, sync iCloud, serveur MCP | open source | Swift + libghostty |
| SSHive | SSH, SFTP, RDP, VNC, tunnels, broadcast, MCP, import `MobaXterm.ini` | Pro 11,99 USD une fois | MAS |
| Noden | SSH, SFTP double panneau, RDP, série, commandes IA | n.c. | natif |
| Quay | voir §1 | gratuit MIT | Swift + libghostty |
| Mongrel, CtrlOps, Pane | variantes « tout-en-un » | divers | Tauri / autres |

Constats :
- Le créneau « MobaXterm pour Mac » est saturé (≥ 10 produits actifs, plusieurs gratuits, plusieurs de 2026).
  Concurrence : 1-2/5. Comme produit à vendre, l'angle est faible ; comme outil personnel ou open source, aucun obstacle.
- Trou constant chez tous les natifs : pas de serveur X11 intégré (tous renvoient à XQuartz), aucune intégration XQuartz soignée.
- Non vérifié : parts d'usage réelles, prix Noden, contenu exact des achats intégrés Upshell.

## 3. Décisions d'architecture

### D1 — Base : feuille blanche (décidé par Rayan le 2026-11-10)
Quay n'est pas utilisé : ni fork, ni reprise de fichiers. Nouveau dépôt, nouveau projet.
Seuls des principes généraux observés restent des références de conception (processus superviseur au bout du pty,
secrets livrés par askpass sur socket Unix), réécrits de zéro.

### D2 — Moteur de terminal
| | SwiftTerm | libghostty |
|---|---|---|
| Langage | 100 % Swift, SPM | Zig/C, xcframework à compiler |
| Rendu | Metal depuis 03/2026 (v1.99.x, actif) | Metal, référence du marché |
| Stabilité API | bibliothèque Swift classique | `libghostty-vt` 1.0 stable (2026-11-06) = émulation seule ; la surface complète avec rendu reste non garantie |

Recommandation : SwiftTerm (cohérent avec « full Swift »), derrière un protocole `TerminalEngine` pour pouvoir changer.
À confirmer par le spike S2.

### D3 — Transport SSH
| | A. OpenSSH système + ControlMaster | B. In-process (swift-nio-ssh / Citadel) |
|---|---|---|
| Compatibilité | totale : `~/.ssh/config`, ProxyJump/ProxyCommand, agent 1Password, clés FIDO, Kerberos | partielle, à réimplémenter |
| SFTP sur la même connexion | oui : `ssh -S sock -s sftp` + client SFTP v3 écrit en Swift | oui, natif |
| Tunnels dynamiques | `ssh -O forward` / `-O cancel` sur le maître | natif |
| Crypto à maintenir | aucune | la nôtre (via NIOSSH) |
| App Sandbox / Mac App Store | non (distribution directe) | oui |

Recommandation : A pour la V1 (moindre risque, pas de crypto à porter), protocole `SSHTransport` pour ajouter B plus tard.
Conséquence : distribution directe (DMG + Sparkle), pas de Mac App Store. À confirmer par le spike S1.

## 4. Périmètre fonctionnel vs MobaXterm

| Fonction MobaXterm | Version | Approche |
|---|---|---|
| Sessions enregistrées, dossiers, recherche | V1 | SwiftData, import `~/.ssh/config` |
| Terminal à onglets + panneaux scindés | V1 | SwiftTerm |
| Navigateur SFTP latéral qui suit le dossier du terminal | V1 | SFTP v3 sur ControlMaster + OSC 7 |
| Glisser-déposer, file de transferts, Quick Look | V1 | NSFilePromiseProvider |
| Édition de fichier distant (rapatrie, surveille, renvoie) | V1 | FSEvents + éditeur par défaut |
| Tunnels graphiques L/R/D | V1 | `ssh -O forward` |
| Bastion / passerelle SSH | V1 | ProxyJump |
| Multi-exécution | V1 | diffusion des frappes vers N panneaux, garde-fou visuel |
| Secrets | V1 | Keychain + askpass sur socket Unix |
| Reconnexion automatique | V1 | processus superviseur au bout du pty |
| Macros / snippets | V1.1 | enregistrement des frappes |
| Import `MobaXterm.ini`, PuTTY, Termius | V1.1 | analyseurs dédiés |
| X11 | V1.1 | détection/lancement XQuartz + `ssh -Y`, pas de serveur X maison |
| Série | V1.2 | termios POSIX |
| Telnet | V1.2 | Network.framework |
| VNC | V2 | bibliothèque Swift tierce à valider, sinon renvoi vers Partage d'écran |
| RDP | V2 | FreeRDP (C) — sort du « full Swift », à décider |
| Serveurs embarqués (TFTP, FTP, HTTP), MobApt | hors périmètre | sans objet sur macOS |

## 5. Jalons

| Jalon | Contenu | Critère de sortie vérifiable |
|---|---|---|
| S1 spike SSH | maître ControlMaster + `-s sftp` piloté depuis Swift, `-O forward` | listage d'un dossier et tunnel ouvert sur le NAS, sans seconde authentification |
| S2 spike terminal | fenêtre minimale SwiftTerm Metal reliée à `ssh` | `vim`, `htop`, `tmux`, débit `cat` gros fichier, IME, comparés à Ghostty |
| M0 socle | projet XcodeGen, cible macOS 15+, Swift 6, protocoles `TerminalEngine` / `SSHTransport`, tests | build + tests verts en ligne de commande |
| M1 sessions | modèles, barre latérale, onglets, panneaux, secrets, reconnexion | 5 hôtes réels ouverts, reconnexion après coupure réseau |
| M2 SFTP | navigateur latéral, suivi du dossier, transferts, édition distante | envoi/réception 1 Go, reprise après coupure, édition aller-retour |
| M3 tunnels + multi-exec | gestionnaire de tunnels, diffusion | tunnel L/R/D actif vérifié par `curl`, commande sur 3 hôtes |
| M4 distribution | signature, notarisation, DMG, Sparkle | installation propre sur un Mac vierge |
| M5 V1.1 | macros, imports, X11 via XQuartz | `xeyes` affiché en un clic |

## 6. Risques

- Marché saturé : sans angle différenciant net (X11 soigné, import MobaXterm, qualité du SFTP latéral), valeur commerciale faible.
- SwiftTerm : fidélité inférieure à Ghostty sur certains cas limites ; le protocole `TerminalEngine` limite le coût d'un changement.
- Client SFTP v3 maison : environ 1 500 lignes, à tester contre OpenSSH, Synology, serveurs SFTP restreints.
- ControlMaster : sockets orphelins, longueur de chemin limitée (104 octets), comportement à la mise en veille.

## 7. Décisions attendues de Rayan

1. Finalité : outil personnel, open source, ou produit à vendre.
2. ~~D1~~ tranché : feuille blanche.
3. « Full Swift » strict (exclut libghostty et FreeRDP) ou simple préférence.
4. ~~Nom~~ tranché le 2026-11-10 : **Escale** (aucun client SSH homonyme trouvé ; escale.com/.io pris, domaine à choisir).

## 8. Résultats des spikes (2026-11-10)

Dossier : `~/.hermes/cache/scratch/spikes-ssh/` (jetable, purgé après 24 h d'inactivité — README de chaque spike à copier si besoin).

### S1 — OpenSSH + ControlMaster + SFTP v3 en Swift : VALIDÉ
Rejoué par l'agent principal (`run-all.sh`, exit 0, 74 s), cible = sshd local non privilégié 127.0.0.1:2222.
- Canal SFTP sur maître existant : ~8 ms. `ls` de 6002 entrées : ~20 ms. 1 Go put/get : ~2 Go/s en loopback, SHA-256 identiques.
- Tunnels `-L` et `-D` ajoutés/retirés à chaud, vérifiés par curl. Mort du maître détectée en 20-165 ms.
- 10 sessions par maître (MaxSessions), la 11e est refusée.
- Serveur restreint réel (NAS) : refus SFTP et refus de tunnel détectés en ~1 s, sans blocage.

Invariants à reporter dans le code réel :
1. Tout client secondaire passe `-o ControlMaster=no -o ProxyCommand=/usr/bin/false`, sinon ssh rouvre en silence une nouvelle connexion quand le maître refuse la session.
2. Supprimer un socket mort avant `ssh -M` (sinon multiplexage désactivé sans erreur).
3. `-O forward` et `-O cancel` renvoient 0 même en cas de refus : sonder le port local et lire le journal du maître.
4. Compter les sessions par maître (limite 10 par défaut) et ouvrir un second maître au-delà.
5. Chemin de socket court (limite ~104 octets).

Non couvert : lien avec latence réelle, coupure réseau sans RST, mot de passe/2FA via askpass, reprise de transfert.

### S2 — SwiftTerm 1.99.3 : PARTIEL (retenu, avec abstraction)
Non rejoué par l'agent principal ; vérifié par relecture du README, de `metrics.json` et d'une capture tmux.
- Débit `cat` 100 Mio : égal à Ghostty 1.4.0 en ASCII et SGR (0,4-0,5 s), 1,4x plus lent en CJK+emoji, ~6x plus rapide que Terminal.app.
- Mémoire : ~160 Mio pour 100 000 lignes de scrollback.
- Conformité : 79 OK / 2 KO / 3 non testés sur 84 ; vim, tmux, htop, images sixel/kitty/iTerm2 OK.
- KO : accessibilité VoiceOver absente (rôle AXUnknown) ; frappes non interceptables avec `LocalProcessTerminalView`.
- Risques : IME (issues #825/#826), mainteneur principal = 74 % des commits.

Décisions qui en découlent :
1. `TerminalView` nue + transport maison (jamais `LocalProcessTerminalView`) — nécessaire pour la multi-exécution.
2. Protocole `TerminalEngine` obligatoire ; aucun type SwiftTerm hors de l'adaptateur.
3. Metal activé avec repli CoreGraphics.
4. OSC 52 : lecture du presse-papiers refusée par défaut.
5. Captures de test : `screencapture -l <windowID>` (cacheDisplay sort noir avec Metal).
6. Spike S3 à prévoir avant M1 : IME réel (CJK, touches mortes AZERTY) et accessibilité.

## 9. Avancement (2026-11-10)

Depot `~/Documents/Escale`, nom retenu : Escale. `scripts/test.sh` = tests du coeur + build de l'app.

Fait et verifie (58 tests, dont 16 contre un sshd local non privilegie) :
- M0 socle : XcodeGen, EscaleCore, contrats `SSHTransport`, `ByteChannel`, `TerminalEngine`.
- `SFTPClient` (v3, transferts en flux, reprise, annulation, extensions posix-rename et limits).
- `OpenSSHTransport` (maitre ControlMaster, canal SFTP, tunnels L/R/D verifies par sonde, plafond de sessions).
- `PTYProcess` (forkpty : `posix_spawn` + SETSID n'acquiert pas le terminal de controle sous Darwin).
- `SwiftTermEngine` + fenetre terminal unique, auto-test `--selftest <dossier>` (13 verifications, captures).
- Test d'assemblage : shell interactif dans un pty + SFTP sur une seule authentification.

Reste pour M1 : modele de sessions persistant, barre laterale, onglets, panneaux, askpass/Keychain (mot de passe, 2FA),
reconnexion, branchement de `OpenSSHTransport` dans l'app (aujourd'hui la fenetre lance un shell local ou `--command`).

Dettes connues :
- SFTP : pas de delai par requete apres negociation ; reprise sans verification du contenu ; fenetre fixe (32 x 32 Kio)
  non ajustee a la latence ; rien de mesure sur un lien reel.
- PTY : un fd ouvert par un autre thread entre l'inventaire et le fork peut fuir vers le fils.
- Terminal : IME et accessibilite non verifies (spike S3) ; politique OSC 52 codee mais non testee.
- Compteur de sessions shell : decremente a la main (`shellSessionDidEnd`), a lier a la fin du pty.

### Vague 2 (2026-11-10, suite)

Fait et verifie (137 tests du coeur, recette `selftest-ssh.sh` a 65 verifications) :
- Coeur `Library/` : `FileHostRepository` (JSON versionne, 0600, fichier corrompu mis de cote), operations de
  bibliotheque, `SSHConfigImporter` (lecture seule, hote = alias), `HostSearch`.
- Coeur `Secrets/` : `KeychainSecretStore`, `AskpassServer`/`AskpassClient` (socket Unix, jeton, meme uid),
  `StoredSecretResponder`, option `askpass` d'`OpenSSHTransport`. Phrase de passe et cle d'hote testees de bout en bout.
- App : barre laterale, onglets, plusieurs onglets par connexion, terminal local, reconnexion qui garde l'ecran,
  second maitre au-dela de 9 sessions.

Pas encore branche dans l'app : `FileHostRepository` et `HostSearch` (l'app a un depot et un filtre provisoires),
import ssh_config, askpass et ses dialogues. Non teste : connexion par mot de passe reussie et 2FA (sshd local sans PAM),
raccourcis clavier reels, glisser-deposer des onglets, interactions de la barre laterale, mode clair.
Defauts visuels connus : bandeau de reconnexion qui recouvre les premieres lignes, premiere ligne du terminal rognee
sous la barre d'onglets, chemin de cle tronque dans la feuille d'edition.

### Vague 3 : fin de M1 (2026-11-11)

Fait et verifie (recettes ssh 65, auth 99, panes 138 verifications ; coeur 137 tests) :
- App branchee sur `FileHostRepository`, `HostSearch` (surlignage), import ssh_config (feuille, lecture seule).
- Authentification interactive : l'app est son propre SSH_ASKPASS (`AskpassClient.runIfRequested()` en tete de main),
  file de dialogues (mot de passe, phrase de passe, code, cle d'hote inconnue), memorisation Trousseau apres succes,
  cle d'hote modifiee = echec dedie sans dialogue, annulation sans nouvelle tentative.
- Panneaux scindes (`PaneLayout`, un `PaneHostView` pour tous les moteurs), sessions comptees par panneau,
  reconnexion par panneau, bandeau hors de la grille.

Non teste : mot de passe reellement accepte et 2FA reelle (a essayer sur un vrai serveur), evenements clavier et souris
reels (raccourcis, glisser des separateurs, clics, survol), mode clair, VoiceOver, IME (spike S3 toujours du).
Dettes : `PaneMenu` installe le menu Terminal par code avec un minuteur (a migrer dans les commandes SwiftUI de
`EscaleApp`) ; texte du bandeau tronque dans un panneau etroit ; en-tete du dialogue de cle d'hote desaligne ;
captures de `selftest-ssh.sh` parfois perimees apres reconnexion (le texte du tampon, lui, est verifie).

### M5 macros et X11 (branche m-macros-x11)
- **Macros** (`EscaleCore/Macros/`, `Escale/Macros/`) : `Macro` = étapes texte (`\n` = Entrée) / attente (ms) / touche spéciale (`MacroKey`, séquences xterm), raccourci ⌃⌥1..9 unique par portée, portée globale ou hôte. Dépôt `macros.json` à côté de `library.json` (écriture atomique, 0600, fichier illisible mis de côté). Aucun secret : avertissement non bloquant dans l'éditeur si une étape ressemble à un mot de passe (`-pXXX`, `password=`…) et bandeau pendant l'enregistrement.
- Enregistrement : `TerminalSession.inputObservers["macros"]` sur le panneau actif (`MacroRecorder` fusionne les octets en étapes). Lecture : `TerminalSession.write` (pas d'écho aux observateurs) sur le panneau actif ou sur tous les panneaux de l'onglet (sans dépendre de multiexec). Menu « Macros », gestionnaire en feuille (`activeFeatureSheet = "macros"`).
- **X11** : `ConnectionManager.sshOptions(for:)` ajoute `ForwardX11=yes`, `ForwardX11Trusted=no` (défaut ; « mode confiance » opt-in dans l'éditeur d'hôte), `XAuthLocation` et `DISPLAY` (socket launchd XQuartz) au **maître** seulement si l'hôte a `x11Forwarding` ET XQuartz est détecté ; sinon aucune option X11 (jamais de `-X` sans XQuartz) et une note dans le terminal. « Lancer une application X11… » (menu hôte) exécute la commande par un client secondaire sur le maître (`-o ControlMaster=no -o ProxyCommand=/usr/bin/false`, invariant 2), avec le forward X11 hérité du maître.
- Tests : `swift test --filter "Macros|X11"` (dont sshd local `X11Forwarding yes` + faux xauth + faux serveur X : DISPLAY distant `localhost:10`, connexion X rapatriée sur le serveur local) ; `scripts/selftest-macros.sh`.
- **Reste à valider par Rayan** : affichage réel de `xeyes` en un clic après installation de XQuartz (non installé ici, sudo requis) ; le mode non confiance (extension SECURITY) n'est vérifié qu'avec un vrai xauth.
