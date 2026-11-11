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
6. Spike S3 : IME (CJK, touches mortes AZERTY) et accessibilité — PARTIEL, voir « Spike S3 + terminal ».

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
- SFTP : rien de mesure sur un lien reel (latence), seulement loopback et simulation (dette de M1 sur delai, reprise,
  fenetre et fd du PTY soldee, voir « M2 coeur SFTP »).
- Terminal : IME et accessibilite traites par le spike S3 (voir plus bas) ; politique OSC 52 codee mais non testee.
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

### M2 coeur SFTP (branche m-sftp-core)

Fait et verifie (coeur : 157 tests, `scripts/test.sh` vert) :
- Delai par requete : `SFTPClientConfiguration.requestTimeout` (60 s par defaut, `nil` = aucun). Une veille unique compare
  l'instant courant au dernier signe de vie (reponse recue) : un lien lent mais vivant n'expire pas. Echec en
  `SFTPError.requestTimeout`, requete liberee, reponse tardive ignoree (canal coherent) ; apres `maxConsecutiveTimeouts` (3)
  delais sans reponse, canal declare mort (`channelClosed`).
- Fenetre adaptative (`SFTPWindowController`) : mesure du debit par intervalles de 250 ms, x1,5 tant que le gain depasse 10 %,
  retour au palier precedent sur plateau, bornes 4...256 (`adaptiveWindow`, `minWindow`, `maxWindow`; `window` = valeur initiale).
  Valide par simulation de liens (bande passante x latence) ; non mesure sur un vrai lien distant.
- Reprise verifiee : `downloadResuming` / `uploadResuming` comparent des SHA-256 de tete (64 Kio) et de queue (1 Mio) du prefixe
  local contre distant (`.full` : tout le prefixe), sinon repart de zero (`SFTPTransferOutcome.restartReason`).
  OpenSSH n'a pas `check-file` : le distant est relu. Une modification au milieu d'un long prefixe n'est vue qu'avec `.full`.
- Progression et annulation : `startDownload` / `startUpload` renvoient un `SFTPTransferTask` (`progress` : AsyncStream de
  `SFTPTransferSnapshot` octets, total, debit lisse, fenetre, duree ; `cancel()` ; `outcome`). Les anciens `download`/`upload`
  sont inchanges (et beneficient de la fenetre adaptative).
- PTY : le fils ferme tout 3..<limite apres le fork (plus d'inventaire prealable) ; test de course avec un thread qui ouvre des fd.
- Tests contre sshd local : 1 Gio aller-retour SHA-256 (~14 s envoi, 4 a 10 s retour selon la charge de la machine), 256 Mio avec
  coupure du maitre ssh puis reprise (envoi et reception), mort du sftp-server, prefixe modifie (queue, tete, milieu), delai.

Reste : lien reel a latence (NAS, VPS) ; blocs de 64 Kio quand `limits@openssh.com` l'autorise (non fait, reste 32 Kio).

### M4 distribution (2026-11-11)

Fait et verifie (procedure : `docs/RELEASE.md`, script : `scripts/release.sh`) :
- Release signee Developer ID (team 5FMH389VS7) + runtime durci, entitlements vides (pas de sandbox) ; version via
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`. Debug reste ad hoc.
- Sparkle 2.10.1 (SwiftPM) : `UpdateFeature`, menu « Rechercher les mises a jour... », `SUPublicEDKey` dans l'Info.plist,
  cle privee EdDSA dans le Trousseau (compte `escale`). Desactive en selftest et si `ESCALE_FEED_URL` est vide (defaut).
- Piege : les XPC/Updater imbriques de Sparkle ne sont pas re-signes par Xcode (notarisation refusee) : re-signature explicite dans `release.sh`.
- Notarisation app + DMG acceptee, agrafage, `spctl` « Notarized Developer ID », appcast genere dans `dist/updates/`.
- Installation propre approximee (DMG monte, copie en quarantaine, spctl, `--selftest-panes` sur le binaire Release).

A faire : test sur un Mac vierge ; choix du domaine et publication du flux (voir RELEASE.md) ; icone d'app (aucune pour l'instant).

### M3 tunnels (2026-11-11)
- **Cœur** (`EscaleCore/Tunnels/`) : `TunnelController` (actor) ouvre/ferme sur le maître existant via `OpenSSHTransport.addTunnel/removeTunnel` (`ssh -O forward/cancel`, déjà présents) ; états `stopped/opening/active/failed(message)`. `TunnelValidation` : ports, adresses, doublons, avertissements (écoute non-loopback, GatewayPorts pour R, port privilégié) ; `TunnelSpec.clientURL` (`http://…` ou `socks5://…`).
- **Vérification (invariant 4)** : L/D : `bind` préalable (port occupé → « déjà utilisé par un autre programme »), puis sonde du port local et journal du maître côté transport. R : refus remonté par `-O forward`, puis sonde distante `bash /dev/tcp` dans une session exec courte (choisie plutôt que le seul journal, vide en cas de succès) ; si la sonde ne peut pas répondre, on se fie au serveur.
- **Correctif transport** : `OpenSSHTransport.connect()` vide sa liste de tunnels ouverts (un maître neuf n'a aucun forwarding) ; sans cela un tunnel de l'ancien maître mort n'était jamais rouvert.
- **App** (`Escale/Tunnels/`) : `TunnelFeature` (observateur `linkObservers["tunnels"]` : `.connected` rouvre les tunnels voulus + `autoStart`, `.lost/.disconnected` les marque arrêtés ; surveillance périodique du maître ; un tunnel voulu retient le lien, la connexion survit à la fermeture du dernier onglet). UI : `TunnelEditorSection` (fiche d'hôte), gestionnaire en feuille ⇧⌘T (`activeFeatureSheet = "tunnels"`), « Tunnels… » dans le menu d'hôte, copie d'URL.
- **Preuves** : `swift test` (tunnels L/D/R par curl, port occupé, `AllowTcpForwarding no`, cancel effectif, coupure du maître) ; `scripts/selftest-tunnels.sh` (connexion, autoStart, L/R/D par curl, port occupé, arrêt, SIGKILL du maître, rétablissement auto, 30 contrôles).
- **Limites** : IPv6 non pris en charge dans les adresses de tunnel ; pas de modification d'un tunnel actif (arrêter puis relancer) ; R sans bash côté serveur = confiance au serveur ; `-R 0` (port attribué) non géré.

### M3 multi-execution

Dossier `Escale/MultiExec/` + coeur `Packages/EscaleCore/Sources/EscaleCore/MultiExec/`.
- **Diffusion de saisie** (`MultiExecFeature`) : portee = panneaux de l'onglet, tous les onglets, ou selection (feuille).
  Chaque panneau du groupe porte l'observateur `inputObservers["multiexec"]` qui rejoue les octets bruts vers les autres
  par `TerminalSession.write` (sans re-notification : pas de boucle). Un minuteur (0,4 s) resynchronise le groupe
  (panneaux crees/fermes). `BroadcastFilter` ecarte les reponses automatiques du terminal (position du curseur, DA,
  focus, souris, OSC) qui ne sont pas des frappes. Collage = un seul envoi par destinataire. Indicateur : bordure rouge
  sur la vue du moteur + bandeau rouge (boutons Choisir / Arreter). Menu « Multi-execution » : ⌥⌘I bascule. Pas de
  raccourci Echap (il serait diffuse comme une touche) : sortie par ⌥⌘I ou le bandeau.
- **Execution groupee** : menu de la selection multiple (barre laterale) ou menu Multi-execution (hotes connectes) →
  feuille (commande, delai 10 s a 5 min) → `GroupExec` en parallele (16 max) ; `OpenSSHTransport.exec` =
  `ssh -T -n -o BatchMode=yes` avec le prefixe secondaire (invariant 2), compte dans le plafond de sessions
  (invariant 5), sortie bornee a 64 Kio par flux (le reste est lu puis jete), delai = SIGTERM puis SIGKILL.
  Hotes non connectes : connectes d'abord par le lien partage (dialogues d'authentification habituels), puis lien
  relache (deconnexion apres le delai de grace si aucun onglet). Resultats dans un panneau bas : etat, code, duree,
  stdout/stderr, Relancer, Copier tout / par hote.
- **Preuves** : `swift test --filter MultiExec` (9 tests : filtre, exec, troncature, plafond, delai, 3 hotes codes 0/3/7,
  parallelisme, rapport) ; `scripts/selftest-multiexec.sh` (64 verifications : diffusion sur 3 panneaux, collage, Ctrl-C,
  nouveau panneau, arret, selection, tous onglets, menu ⌥⌘I, commande sur 3 hotes dont 2 a connecter, code 3, relancer,
  delai, hote injoignable).
- **Non teste / limites** : frappes clavier reelles (la recette injecte par `engine.sendInput`, chemin du delegue) ;
  la bordure rouge est sur la vue du moteur (pas dans `PaneHostView`) ; pas de commande par hote dans l'UI (le coeur
  l'accepte via `GroupExecTarget.command`) ; menu « hotes connectes » seulement, pas de choix par dossier.

### M5 macros et X11 (branche m-macros-x11)
- **Macros** (`EscaleCore/Macros/`, `Escale/Macros/`) : `Macro` = étapes texte (`\n` = Entrée) / attente (ms) / touche spéciale (`MacroKey`, séquences xterm), raccourci ⌃⌥1..9 unique par portée, portée globale ou hôte. Dépôt `macros.json` à côté de `library.json` (écriture atomique, 0600, fichier illisible mis de côté). Aucun secret : avertissement non bloquant dans l'éditeur si une étape ressemble à un mot de passe (`-pXXX`, `password=`…) et bandeau pendant l'enregistrement.
- Enregistrement : `TerminalSession.inputObservers["macros"]` sur le panneau actif (`MacroRecorder` fusionne les octets en étapes). Lecture : `TerminalSession.write` (pas d'écho aux observateurs) sur le panneau actif ou sur tous les panneaux de l'onglet (sans dépendre de multiexec). Menu « Macros », gestionnaire en feuille (`activeFeatureSheet = "macros"`).
- **X11** : `ConnectionManager.sshOptions(for:)` ajoute `ForwardX11=yes`, `ForwardX11Trusted=no` (défaut ; « mode confiance » opt-in dans l'éditeur d'hôte), `XAuthLocation` et `DISPLAY` (socket launchd XQuartz) au **maître** seulement si l'hôte a `x11Forwarding` ET XQuartz est détecté ; sinon aucune option X11 (jamais de `-X` sans XQuartz) et une note dans le terminal. « Lancer une application X11… » (menu hôte) exécute la commande par un client secondaire sur le maître (`-o ControlMaster=no -o ProxyCommand=/usr/bin/false`, invariant 2), avec le forward X11 hérité du maître.
- Tests : `swift test --filter "Macros|X11"` (dont sshd local `X11Forwarding yes` + faux xauth + faux serveur X : DISPLAY distant `localhost:10`, connexion X rapatriée sur le serveur local) ; `scripts/selftest-macros.sh`.
- **Reste à valider par Rayan** : affichage réel de `xeyes` en un clic après installation de XQuartz (non installé ici, sudo requis) ; le mode non confiance (extension SECURITY) n'est vérifié qu'avec un vrai xauth.

### M2 interface SFTP (2026-11-11, branche `m-sftp-ui`)
Code dans `Escale/SFTP/` ; cœur SFTP inchangé (API publique `SFTPClient`, `openSFTPChannel`).
- **Canal** : `SFTPHostSession` (un par hôte) ouvre un client SFTP sur le lien maître de l'hôte (liens des onglets d'abord,
  sinon un lien pris pour l'occasion et relâché à la fermeture). Compte dans `sessionCount` (invariant 5) ; un lien plein
  (`sessionRefused`) fait essayer le suivant. Observateur `linkObservers["sftp"]` : `lost` → état « perdu », `connected` →
  canal rouvert au même dossier, `disconnected` → fermeture. Aucune nouvelle authentification.
- **Navigateur** : inspecteur SwiftUI (⌥⌘F, menu Présentation, ou « Parcourir les fichiers (SFTP) » du menu d'hôte) lié à
  l'onglet actif. Liste (nom, taille, date, droits), chemin éditable (`~`, relatif, absolu), précédent/suivant/parent,
  actualiser, fichiers cachés, nouveau dossier, renommer, supprimer (confirmation, récursif), copier le chemin, menu
  contextuel. Chemins gérés en octets. La fenêtre s'élargit à l'ouverture de l'inspecteur (sinon SwiftUI boucle sur la mise
  en page : `NSGenericException` constraints, constaté sur 880 px).
- **Glisser-déposer** : Finder → liste (ou ligne de dossier) = envoi, confirmation avant remplacement ; ligne → Finder =
  `Transferable` (`FileRepresentation`) qui télécharge à la demande sous `~/Library/Caches/<bundle>/drag/`.
  Non testé au pointeur (la recette teste `upload`/`exportForDrag`).
- **Transferts** : `SFTPTransferQueue` commune, 3 simultanés max, progression/débit lissé, annuler, réessayer (repart de
  zéro : pas de reprise côté UI), dossiers expansés fichier par fichier, collision de nom en réception → « nom 2.ext ».
- **Suivi du terminal** : OSC 7 déjà remonté par `TerminalSession.workingDirectory` (aucun changement moteur nécessaire).
  `SFTPFeature` observe le panneau actif et relaie vers le navigateur de l'hôte. Si le shell n'annonce rien, bouton
  « Activer le suivi » → confirmation → fonction `__escale_osc7` tapée dans le shell (bash `PROMPT_COMMAND` / zsh `precmd`).
- **Édition distante** : téléchargement dans `~/Library/Caches/<bundle>/edit/<uuid>/`, ouverture par `NSWorkspace`,
  surveillance `DispatchSource` (fichier + dossier, réarmée après remplacement atomique) + sondage 1 s, renvoi à chaque
  sauvegarde. Conflit (taille/mtime distants ≠ ceux du téléchargement) : demande Écraser / Garder le distant ; « Renvoyer »
  force. « Terminer » supprime le temporaire.
- **Recette** : `scripts/selftest-sftp.sh` (sshd local) — 78 vérifications : connexion unique, `sessionCount`, liste du home,
  mkdir/navigation, envoi/réception (fichier, dossier), file (borne, annulation, réessai), renommer/supprimer, OSC 7
  (`cd /tmp`, chemin avec espace, suivi coupé/réactivé), édition (en place, atomique, conflits), perte du maître
  (`kill -9`) puis réouverture du canal, absence de processus ssh résiduel.
- **Limites** : pas de reprise de transfert dans l'UI, pas de tri par colonne, pas de glisser distant → distant, pas de
  téléversement de la sélection du Finder via menu « Services ».

### M5 imports (sessions MobaXterm, PuTTY, CSV)

Cœur `Packages/EscaleCore/Sources/EscaleCore/Import/` : protocole `SessionImporter` (lecture seule, `parse(data:)` / `parse(fileAt:)`),
`MobaXtermImporter` (`.mxtsessions` ou `MobaXterm.ini`, Windows-1252, dossiers `SubRep`, passerelles → `jumpHosts`, X11),
`PuTTYRegImporter` (export `.reg` UTF-16LE, `PortForwardings` → `TunnelSpec`, `X11Forward`, `/` dans le nom → dossiers),
`CSVSessionImporter` (`name,host,port,user,folder,tags`, séparateur `,` `;` ou tab), `SessionImportMerge` (dédoublonnage host+port+user,
dossiers recréés sous le dossier cible, dossier existant réutilisé sans tenir compte de la casse). Formats MobaXterm et PuTTY
documentés en commentaire de tête avec leurs sources publiques.
- Jamais de secret : mots de passe (champ MobaXterm, `[Passwords]`, `ProxyPassword`, colonne CSV `password`) ignorés et comptés (« n mots de passe non importés »).
- Clés `.ppk` ou chemins Windows : non reprises, avertissement avec le chemin d'origine (OpenSSH ne lit pas le .ppk).
- Non importés : sessions non SSH (Telnet, RDP, VNC, FTP, série…), tunnels MobaXterm (hors ligne de session), commandes de connexion.
- App `Escale/Import/` : Fichier › Importer › MobaXterm / PuTTY / CSV (`NSOpenPanel`), feuille d'aperçu (cases, doublons grisés, avertissements,
  dossier cible, « garder les dossiers d'origine »). L'import `~/.ssh/config` reste celui d'`ImportSheet`/`ImportModel`.
- Recette : `scripts/selftest-import.sh` (bibliothèque temporaire `--library`, fixtures `scripts/fixtures/import/` converties en cp1252 / UTF-16LE), `result.json`.

### Integration M2-M5 (2026-11-11)

Sept branches fusionnees dans `main` (squelette `AppFeature` pose avant, un worktree par flux). Corrections d'integration :
- double `execArguments` (X11 vs multi-execution) : celui de la multi-execution devient `batchExecArguments` ;
  `sessionCount` inclut desormais les sessions exec (le plafond de 10 vaut pour tous les clients).
- `SFTPError.requestTimeout` (coeur) traduit dans `SFTPMessages`.
- inspecteur SFTP : SwiftUI construisait le navigateur meme replie et son `.task` ouvrait un canal SFTP des qu'un
  onglet SSH etait actif (recettes ssh/panes : `sessionCount` +1). Vue gardee derriere `if isVisible`.
Verifie sur `main` : `scripts/test.sh` vert (218 tests coeur + build), recettes ssh 65, auth, panes 138, sftp 78,
tunnels 31, multiexec 64, macros 62, import 28 controles : toutes `ok`.

Restes (non verifiables ici ou hors perimetre) :
- Mac vierge : telechargement reel (quarantaine), Gatekeeper, mise a jour Sparkle complete. Domaine et `ESCALE_FEED_URL` a decider.
- XQuartz : `xeyes` en un clic a valider apres installation (sudo). Mode X11 non fiable avec vrai cookie xauth non teste.
- Gestes reels non pilotes : glisser-deposer Finder, clics menus, lien distant a vraie latence. IME/VoiceOver : voir spike S3 (reste le test humain AZERTY/CJK/VoiceOver reels).
- SFTP UI : un transfert reessaye repart de zero (brancher la reprise verifiee du coeur) ; pas de tri par colonne.
- Gestes reels non pilotes : glisser-deposer Finder, clics menus, IME/VoiceOver (spike S3), lien distant a vraie latence.
- SFTP : glisser distant -> distant entre deux hotes differents (non prevu : meme hote seulement) ; mode shell : noms non UTF-8 non adressables, listage `ls` (dernier recours) sans retour a la ligne dans les noms ; gestes reels (⌥ au drop) non pilotes.
- Tunnels : IPv6, `-R 0`, modification d'un tunnel actif. Multi-exec : Echap ne sort pas de la diffusion (diffuse).
- Icone de l'app absente. (Dettes M1 PaneMenu, troncatures, OSC 52 : soldees, voir « Dettes techniques M1 ».)

### Dettes techniques M1 (2026-11-11, branche `v2-tech`)

- Compteur de sessions : `ShellCommand.lease` (`SessionLease`, idempotent, thread-safe) est rendu par `PTYProcess(lease:)` a la fin
  du processus (sortie, kill, echec de lancement) ; `TunnelController` et macros/X11 liberent le leur. Un bail d'avant
  `disconnect()` ne decremente pas le nouveau maitre (generation). Plus aucun `shellSessionDidEnd()` manuel dans l'app
  (reste public pour les tests). `ConnectionManager.trackShell` alimente `shellsStarted/shellsEnded` via `lease.whenReleased`.
- Menu Terminal : `Escale/Views/PaneCommands.swift` (`CommandMenu`), `PaneMenu` et son minuteur supprimes. L'etat grise vient de
  `PaneMenuState` (ObservableObject relie a l'Observation du modele : un `Commands` ne suit pas `@Observable`).
  `PanesSelfTest` verifie titres, raccourcis, etat active (1 panneau, plusieurs, sans onglet) via `NSApp.mainMenu`.
- OSC 52 : ecriture permise, lecture refusee, testees dans `selftest-panes` sur un `NSPasteboard` nomme (`TerminalClipboard.pasteboard`,
  general par defaut) ; `changeCount` du presse-papiers general inchange.
- Mise en page : bandeau compact (2 lignes + boutons dessous, `PaneBanner.height(forWidth:)`) sous 460 pt + infobulle ; en-tete de la
  feuille de cle d'hote : le symbole `questionmark.shield.fill` n'existe pas (icone vide, d'ou le decalage) -> `lock.shield.fill`,
  icone calee a gauche. Chemin de cle de l'editeur : deja tronque au milieu avec infobulle (verifie en capture).
- Captures ssh apres reconnexion : `refreshDisplay` force `displayIfNeeded` + `CATransaction.flush`, trois passes + attente de frame.
- Verifie : coeur 220 tests, recettes ssh 65, auth 99, panes (OSC 52, menu), macros 62, sftp 78, tunnels 31, multiexec 64, import : ok.
- Icone de l'app absente. Dettes M1 inchangees (PaneMenu, troncatures, OSC 52).

### Spike S3 + terminal : IME et accessibilite (2026-11-11) — PARTIEL

Code : `Escale/Terminal/EscaleTerminalView.swift` (sous-classe de `TerminalView`), `SwiftTermEngine` (API ajoutee : `accessibilityLabel`,
`textInputClient`, `isComposing`, compteurs), `TerminalSelfTest`, `scripts/selftest-terminal.sh` (56 controles, `result.json` + capture).
Ajouts dans des fichiers partages : `Pane.init` (libelle « Terminal — <hote> »), `AppModel.featureSelfTests` (option `selftest-terminal`).

Saisie composee (pilotee par appels directs au `NSTextInputClient`, octets lus au delegue ET a travers un vrai pty) :
- OK : `^`+`e` = `c3 aa`, `¨`+`i` = `c3 af`, `^^` = `5e`, `^x` = `5e 78`, annulation sans octet ; japonais `日本` = `e6 97 a5 e6 9c ac` ; chinois `你好`
  = `e4 bd a0 e5 a5 bd` ; aucun octet pendant la composition ; flux pty identique au flux emis.
- Defauts de SwiftTerm 1.99.3 corriges : (1) `insertText` ignorait un `NSAttributedString` (validation de certains IME CJK perdue) ;
  (2) `markedRange`/`selectedRange`/`attributedSubstring` dans des reperes differents (l'IME pouvait remplacer le mauvais texte) ;
  (3) `doCommand(by:)` (non surchargeable : `public override`) envoyait Retour arriere/Echap/fleches pendant la composition : le pont du moteur
  retient toute sortie produite pendant une composition (sauf la validation et `sendInput`, macros/diffusion jamais filtrees) ;
  (4) avec le rendu Metal la `CaretView` interne n'est jamais positionnee : `firstRect` renvoyait le coin bas-gauche de la vue et le texte marque
  s'affichait dans le coin de la fenetre (capture a l'appui). `firstRect` est calcule depuis le curseur de l'ecran et la `CaretView` est recalee
  avant chaque composition (retrouvee par nom de classe : fragile en cas de mise a jour de SwiftTerm, couvert par la recette).
  Mesure : `firstRect` suit le curseur (dx 320 pt pour 40 colonnes, dy 96 pt pour 6 lignes, hauteur = 1 ligne).

Accessibilite (lue par `AXUIElement` sur l'app elle-meme, `AXIsProcessTrusted` = vrai) : AXTextArea, description « Terminal — <hote> », AXValue =
ecran + au plus 200 lignes de scrollback, AXNumberOfCharacters, AXVisibleCharacterRange (ecran vivant), AXSelectedText, AXSelectedTextRange (curseur ou
selection), AXValueChanged limite a 1 par 0,5 s (5 notifications pour ~220 ecritures/s pendant 1,5 s, 0 au repos).
Perf (scrollback 100 000 lignes, 110 000 lignes alimentees en 215 ms) : 1re requete AX 4,7 ms, empreinte memoire +0,9 Mio (un instantane complet
≈ 500 Mio), 150 requetes repetees = 1 seule reconstruction, 5 000 ecritures d'un octet = 0 reconstruction (~1,7 µs chacune).
Les requetes AX in-process s'executent sur le fil appelant : la recette les fait depuis le fil principal (depuis un autre fil, l'assertion d'isolation
`@MainActor` de la vue plante ; avec VoiceOver reel l'appel arrive sur le fil principal).

Reste (PARTIEL) : clavier AZERTY physique et IME systeme reels non pilotes (CGEvent ou changement de source de saisie voleraient le focus / changeraient les
reglages de l'utilisateur) ; panneau de candidats dessine par macOS non vu ; lecture par VoiceOver reel non faite ; AXVisibleCharacterRange = ecran vivant
meme si l'utilisateur a remonte dans l'historique ; AXValue ne couvre pas tout le scrollback (borne voulue) ; sortie retenue pendant une composition
inclut aussi les rapports souris/focus des applications distantes (negligeable).
### M2 SFTP : reprise UI, mode shell, tri, deplacement distant (branche `v2-sftp`)

- **Paquets 64 Kio** : `SFTPClient.chunkSize(configured:preferred:announcedLimit:)` ; avec `limits@openssh.com` les
  READ/WRITE montent a 64 Kio (`SFTPClientConfiguration.limitsChunkSize`) sans depasser la limite annoncee ; sinon 32 Kio.
- **`RemoteFileSystem`** (coeur) : liste, attributs, mkdir/rmdir/remove/rename, `readBlock`/`writeBlock`, `copyItem`,
  `startDownload`/`startUpload` (reprise verifiee), `removeTree`. Implemente par `SFTPClient` et `ShellFileSystem`.
- **`ShellFileSystem`** (sessions exec sur le maitre) : listage `find -printf` (GNU) -> boucle POSIX + `stat` (BSD/GNU)
  -> `ls -lan [--time-style=+%s]`, methode retenue apres le premier succes ; telechargement `dd bs=64k skip=N`
  (reprise alignee sur 64 Kio, prefixe verifie), envoi `cat > f.part` puis `chmod` + `mv` (reprise en `>>`), copie `cp -a`.
  Chemins jamais interpoles : script constant + arguments positionnels entre apostrophes (`ShellQuote`), `env LC_ALL=C /bin/sh -c`.
  `RemoteExecStream` + `OpenSSHTransport.openShellStream` = exec en flux binaire, compte dans `sessionCount` (invariants 2, 5, 13 ;
  `batchStreamArguments`, sans `-n`). `RemoteFileSystemOpener.open` bascule sur le shell quand `openSFTPChannel` echoue
  (`subsystemUnavailable`, canal ferme, negociation) et que `exec` repond ; le repli est memorise par session (pas de retentative SFTP).
- **UI** : bandeau « Mode shell (SFTP indisponible) » + raison ; « repris a X % » (liste des transferts) ; reprise verifiee des la
  2e tentative (« Reessayer ») ; transfert coupe par perte de lien : repart seul a la reconnexion (jusqu'a 5 fois, `resumeInterrupted`
  appele a l'ouverture du canal) ; tri Nom/Taille/Date (en-tetes + menu, `SFTPSort`, UserDefaults `escale.sftp.sort*`, dossiers d'abord) ;
  glisser distant -> distant dans un dossier du meme hote : deplacement (rename), ⌥ = copie (`cp -a` par exec, sinon lecture/ecriture),
  jamais d'ecrasement, refus de deplacer un dossier dans lui-meme (`SFTPHostSession.move`).
- Correctif : un `cd` rapide du terminal n'est plus ecrase par un `stat` plus lent (`followToken`).
- Recettes : `scripts/selftest-sftp.sh` (reprise UI dl/up, coupure du maitre en plein transfert + reprise auto, tri, deplacement/copie
  avec noms hostiles) et `scripts/selftest-sftp-shell.sh` (meme scenario, sshd sans `Subsystem sftp`). Tests coeur : `ShellFileSystemTests`.
