# Release d'Escale (M4 distribution)

Deux scripts : `scripts/release.sh` construit, signe et notarise (artefacts dans `dist/`, ignoré par git, rien n'est
publié) ; `scripts/publish.sh` met cette release en ligne (DMG + appcast Sparkle) sur https://escale-ssh.vercel.app.

## Commande

```
scripts/release.sh [--version X.Y.Z] [--build N] [--skip-notarize] [--no-dmg-style]
```

Étapes : xcodegen → archive Release (Developer ID, runtime durci) → re-signature des composants Sparkle →
vérification (`codesign --verify --deep --strict`, chaque Mach-O : équipe, runtime, horodatage) → notarisation de
l'app + `stapler staple` + `spctl` → DMG (create-dmg, fond simple, lien Applications) → signature, notarisation,
agrafage et `spctl` du DMG → appcast Sparkle (`generate_appcast`). Durée : environ 3 min.

- `--skip-notarize` : saute les deux notarisations (itération rapide ; `spctl` refusera l'app).
- `--no-dmg-style` : saute la mise en forme Finder du DMG (AppleScript), utile en session sans interface.
- `--version` / `--build` : par défaut `MARKETING_VERSION` de `project.yml` et le nombre de commits git. Le build
  doit croître à chaque publication (Sparkle compare `CFBundleVersion`).

Sorties : `dist/Escale.app`, `dist/Escale-<version>.dmg`, `dist/updates/{Escale-<version>.dmg,appcast.xml}`.

## Variables

| Variable | Défaut | Rôle |
|---|---|---|
| `ESCALE_SIGN_IDENTITY` | hash du certificat « Developer ID Application: Rayan Kroubi (5FMH389VS7) » | Identité codesign. Un hash, car deux certificats de même nom existent dans le trousseau (le nom seul serait ambigu). |
| `ESCALE_NOTARY_KEY` | `~/Downloads/05_Technique/AuthKey_G7JK2CFPL3.p8` | **Chemin** de la clé API App Store Connect. Son contenu n'est jamais copié dans le dépôt ni journalisé. |
| `ESCALE_NOTARY_KEY_ID` | `G7JK2CFPL3` | Key ID. |
| `ESCALE_NOTARY_ISSUER` | `fd7a9e88-3c53-47c3-a128-f044f3aabd52` | Issuer ID. |
| `ESCALE_FEED_URL` | `https://escale-ssh.vercel.app/updates/appcast.xml` | URL du flux Sparkle écrite dans `SUFeedURL`. **Figée dans les apps livrées depuis la 1.0.0 : ne pas la changer.** `ESCALE_FEED_URL=` (vide explicite) = build sans mises à jour (menu grisé, aucun accès réseau). |
| `ESCALE_DOWNLOAD_URL_PREFIX` | `https://escale-ssh.vercel.app/updates/` | Préfixe des URL de DMG dans l'appcast. |
| `ESCALE_SPARKLE_ACCOUNT` | `escale` | Compte Trousseau de la clé EdDSA. |

## Signature et runtime durci

- Configuration Release de `project.yml` : signature manuelle, `DEVELOPMENT_TEAM 5FMH389VS7`, `ENABLE_HARDENED_RUNTIME`,
  horodatage sécurisé. Debug reste ad hoc (`-`) : `scripts/test.sh` et les selftests ne dépendent pas du trousseau.
  La config est portée par la cible `Escale` (pas de `CODE_SIGN_IDENTITY` en ligne de commande : il s'appliquerait
  aussi aux plugins SwiftPM de SwiftTerm et ferait échouer l'archive).
- `Escale/Escale.entitlements` est **vide** volontairement : pas de sandbox (l'app lance `/usr/bin/ssh`, lit
  `~/.ssh/config`, et crée des sockets/fichiers temporaires), et aucune exception du runtime durci (pas de JIT,
  pas de `DYLD_*`, pas de bibliothèque non signée). `/usr/bin/ssh` est un binaire système : il n'exige rien de l'app.
- Pas de helper askpass séparé : l'app est son propre `SSH_ASKPASS` (`AskpassClient.runIfRequested()` en tête de `main`).
  Il n'y a donc rien d'autre à embarquer ni à signer ; le script le vérifie en contrôlant tous les Mach-O du bundle.
- Serveur X11 integre : `Contents/Helpers/EscaleX11.app` (31 dylibs, `X11.bin` patche, outils) est signe Developer ID + runtime
  + horodatage par la phase de build (`scripts/x11-bundle.sh --sign … --runtime`) ; `release.sh` verifie sa presence et chaque Mach-O.
  Premier build sur une machine : telechargement du paquet XQuartz (122 Mo, SHA-256 verifie), garde dans `~/Library/Caches/Escale-build`.
- Sparkle : Xcode ne re-signe pas `Installer.xpc`, `Downloader.xpc`, `Autoupdate`, `Updater.app` avec notre identité
  (Apple rejette alors la notarisation : « not signed with a valid Developer ID » / « no secure timestamp »).
  `release.sh` les re-signe du plus interne au plus externe, puis le framework, puis l'app.

## Clés

- **Notarisation** : clé API `.p8` hors dépôt (chemin ci-dessus).
- **Sparkle EdDSA** : générée par `generate_keys --account escale`, stockée dans le **Trousseau « login »** (compte
  `escale`). Seule la clé publique est dans le dépôt (`SUPublicEDKey` de `project.yml`) :
  `u8/2WiJsdPg8DozixHDr/1UCGjxAY9+EwziR4NHvLkg=`. Afficher la publique : `generate_keys --account escale -p`.
  Sauvegarde : `generate_keys --account escale -x <fichier>` (à ranger hors dépôt, ex. gestionnaire de mots de passe).
  **Perdre cette clé = impossible de publier des mises à jour reconnues par les installations existantes.**
  L'outil est dans `build-release/SourcePackages/artifacts/sparkle/Sparkle/bin/` après un premier `release.sh`.

## Publier : `scripts/publish.sh`

```
scripts/release.sh --version X.Y.Z     # build croissant = nombre de commits : committer avant
scripts/publish.sh --dry-run           # contrôles + build du site, sans déployer
scripts/publish.sh                     # déploiement production + vérification en ligne
git add web/src/release.json web/public/updates/appcast.xml && git commit && git push
```

Hébergement : projet Vercel `escale` (équipe « attila's projects »), domaine `escale-ssh.vercel.app`, site Astro de
`web/`. Déploiement par la CLI (`npx vercel build --prod` puis `deploy --prebuilt --prod`), pas par push git : le DMG
(`*.dmg` ignoré par git) n'existe que dans `web/public/updates/` local et part avec le déploiement.

Contrôles bloquants avant déploiement :
- un seul DMG dans `dist/updates`, nommé d'après la version de l'appcast, qui ne décrit qu'une version ;
- URL du DMG dans l'appcast = `<site>/updates/<dmg>` ; `SUFeedURL` de `dist/Escale.app` = flux du site (une app livrée
  avec un autre flux ne se mettrait plus jamais à jour) ; `CFBundleVersion` = build de l'appcast ;
- `spctl` et `stapler validate` du DMG ; signature EdDSA de l'appcast vérifiée avec la clé du Trousseau ;
- build supérieur ou égal au build en ligne (Sparkle compare `CFBundleVersion` ; égal = republication, signalée).

Ensuite : seul le dernier DMG est gardé dans `web/public/updates/` (l'appcast ne pointe que vers lui ; pas de deltas),
`web/src/release.json` (version, build, nom et taille du DMG) alimente les textes et le bouton du site, puis build,
déploiement et vérification en ligne : appcast identique à `dist/`, DMG identique et signature valide, pages `/` et
`/en` pointant vers le nouveau DMG. Le script ne commite rien.

Pièges :
- `curl … | rg -q` échoue sous `set -o pipefail` (rg ferme la pipe, curl reçoit SIGPIPE) : lire la page dans une
  variable avant de chercher.
- Test bout en bout à faire à la première mise à jour : installer la version en ligne, publier la suivante, lancer
  « Rechercher les mises à jour… » dans le menu Escale.
- Si les DMG doivent rester téléchargeables (anciennes versions), passer à Vercel Blob comme Ardoise.

## Vérifications faites / restant à faire

Faites (voir docs/PLAN.md, M4) : notarisation acceptée (app et DMG), `spctl` « Notarized Developer ID », `stapler validate`,
copie en quarantaine du DMG monté, lancement `--selftest-panes` avec le binaire Release.
**Reste à faire par Rayan : installation sur un Mac vierge** (téléchargement réel avec quarantaine Safari, Gatekeeper
hors ligne grâce à l'agrafage, puis test de mise à jour Sparkle bout en bout une fois le flux publié).
