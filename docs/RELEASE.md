# Release d'Escale (M4 distribution)

Tout se fait avec `scripts/release.sh`. Il ne publie rien : les artefacts restent dans `dist/` (ignoré par git).

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
| `ESCALE_FEED_URL` | vide | URL du flux Sparkle écrite dans `SUFeedURL`. **Vide = mises à jour désactivées** (menu grisé, aucun accès réseau). |
| `ESCALE_DOWNLOAD_URL_PREFIX` | vide | Préfixe des URL de DMG dans l'appcast (ex. `https://exemple.fr/escale/`). Sans lui, l'URL est relative au flux. |
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

## Publier plus tard (à faire par Rayan, domaine non décidé)

1. Choisir l'hébergement HTTPS (domaine, GitHub Pages, S3…).
2. Définir `ESCALE_FEED_URL=https://<domaine>/escale/appcast.xml` et `ESCALE_DOWNLOAD_URL_PREFIX=https://<domaine>/escale/`,
   puis lancer `scripts/release.sh`. **La première version à distribuer doit être construite avec le flux renseigné** :
   une build à `SUFeedURL` vide ne se mettra jamais à jour.
3. Téléverser `dist/updates/Escale-<version>.dmg` et `dist/updates/appcast.xml` à l'URL du flux. Conserver les
   anciens DMG dans `dist/updates` (génère des deltas et garde l'historique) ou les republier avec l'appcast.
4. Page de téléchargement : le DMG notarisé `dist/Escale-<version>.dmg`.
5. Tester : installer l'ancienne version, lancer « Rechercher les mises à jour… » dans le menu Escale.

## Vérifications faites / restant à faire

Faites (voir docs/PLAN.md, M4) : notarisation acceptée (app et DMG), `spctl` « Notarized Developer ID », `stapler validate`,
copie en quarantaine du DMG monté, lancement `--selftest-panes` avec le binaire Release.
**Reste à faire par Rayan : installation sur un Mac vierge** (téléchargement réel avec quarantaine Safari, Gatekeeper
hors ligne grâce à l'agrafage, puis test de mise à jour Sparkle bout en bout une fois le flux publié).
