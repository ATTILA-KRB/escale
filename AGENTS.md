# Escale

Client SSH natif macOS (sessions, SFTP lateral, tunnels, multi-execution). Plan et decisions : `docs/PLAN.md`.

## Structure
- `Packages/EscaleCore` : logique sans UI (modeles, transport SSH, SFTP, pty). Testee par `swift test`.
- `Escale/` : app SwiftUI/AppKit. Le moteur de terminal (SwiftTerm) reste confine a `Escale/Terminal/`.
- `project.yml` : source du projet Xcode (XcodeGen). `Escale.xcodeproj` est genere, non versionne.

## Commandes
- `scripts/test.sh` : tests du coeur + build de l'app. A lancer avant tout commit.

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

## Conventions
- Swift 6, concurrence stricte. Commentaires en francais. Sujets de commit sans accents.
- Recherche : `rg`, jamais `grep`.
