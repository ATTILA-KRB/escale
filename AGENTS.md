# Escale

Client SSH natif macOS (sessions, SFTP lateral, tunnels, multi-execution). Plan et decisions : `docs/PLAN.md`.

## Structure
- `Packages/EscaleCore` : logique sans UI (modeles, transport SSH, SFTP, pty). Testee par `swift test`.
- `Escale/` : app SwiftUI/AppKit. Le moteur de terminal (SwiftTerm) reste confine a `Escale/Terminal/`.
- Modules M2-M5 (`Escale/{SFTP,Tunnels,MultiExec,Macros,Import,Update}/`) : s'accrochent a l'app uniquement par
  `Escale/Features/AppFeature.swift` (commandes, scenes, menus d'hote), `ConnectionManager.linkObservers`,
  `TerminalSession.inputObservers` et `--selftest-<module> <dossier>`.
- `project.yml` : source du projet Xcode (XcodeGen). `Escale.xcodeproj` est genere, non versionne.

## Commandes
- `scripts/test.sh` : tests du coeur + build de l'app. A lancer avant tout commit.
- `scripts/selftest-{ssh,auth,panes,sftp,tunnels,multiexec,macros,import}.sh` : recettes de l'app contre un sshd local
  (ouvrent une fenetre, sans prendre le focus). Resultats dans `$OUT` (result.json + captures).
  A lancer apres tout changement dans `Escale/`, une a la fois (meme dossier `build/`). Sortie vers un fichier,
  pas `| tail` (le garde-fou `sleep` en arriere-plan garde la pipe ouverte).
- `scripts/release.sh [--skip-notarize]` : build Release Developer ID, notarisation, DMG, appcast (`docs/RELEASE.md`).

## Invariants
1. Aucun type SwiftTerm hors de `Escale/Terminal/` : tout passe par `TerminalEngine`.
2. Tout client ssh secondaire passe `-o ControlMaster=no -o ProxyCommand=/usr/bin/false`
   (sinon ssh rouvre en silence une connexion quand le maitre refuse la session).
3. Supprimer un socket de controle mort avant `ssh -M`.
4. `ssh -O forward/cancel` renvoie 0 meme en cas de refus : verifier par sonde du port et journal du maitre.
5. Au plus 10 sessions par connexion maitre (MaxSessions par defaut).
6. Chemin de socket de controle court (limite ~104 octets).
7. Aucun secret dans les modeles ni sur disque : references Keychain uniquement.
8. Ne jamais ecrire dans `~/.ssh`.
9. Ne jamais tuer des processus ssh par motif large (`pkill -f "ssh -M"`) : viser un pid ou un chemin propre a la
   session. Un motif large coupe les connexions d'une app en service et fait echouer les tests lances en parallele.
10. Une cle d'hote modifiee est toujours refusee, jamais proposee a l'utilisateur comme simple confirmation.
11. Un secret n'est memorise dans le Keychain qu'apres une connexion reussie ; jamais dans un journal ni un message d'erreur.
12. Un module n'ouvre aucune session sur le maitre sans action de l'utilisateur : SwiftUI evalue le contenu d'un
    `.inspector` meme replie, donc garder sa vue derriere `if visible` (sinon `sessionCount` derive).
13. Deux lignes exec distinctes : `execArguments` (applications X11, avec ForwardX11) et `batchExecArguments`
    (multi-execution : BatchMode, sans X11). Toute session exec compte dans `sessionCount`.

## Conventions
- Swift 6, concurrence stricte. Commentaires en francais. Sujets de commit sans accents.
- Recherche : `rg`, jamais `grep`.
