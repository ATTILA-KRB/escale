# Interface : rapprochement avec MobaXterm

Objectif : qu'un utilisateur de MobaXterm (Windows) retrouve ses repères dans Escale, sans renoncer aux conventions
macOS (barre d'outils unifiée, menus, raccourcis ⌘, thème clair/sombre du système). On reprend la **disposition** et le
**vocabulaire**, pas l'habillage.

Sources : documentation officielle (`mobaxterm.mobatek.net/documentation.html`) et captures officielles (fenêtre
principale, navigateur SFTP latéral, monitoring distant, dialogue de session).

## Correspondance des zones

| MobaXterm | Escale | État |
|---|---|---|
| Barre de boutons (Session, Servers, Tools, Split, MultiExec, Tunneling, X server…) | `MainToolbar` : Session, Terminal, Connexion, Scinder, MultiExec, Tunnels, Fichiers, Macros, X11 (+ Importer, masqué par défaut). Icône et texte, personnalisable | fait |
| Champ « Quick connect » | Champ de la barre latérale « Connexion rapide ou recherche » (⇧⌘K) + champ de la page d'accueil. `utilisateur@hôte:port` | fait |
| Onglets verticaux de la barre latérale : Sessions, Tools, Macros, Sftp | Sélecteur de volets en tête de barre latérale : Sessions, Fichiers, Outils, Macros (menu Présentation) | fait |
| Arbre des sessions (dossiers, icône par protocole) | Volet Sessions : lignes denses (une ligne), icône colorée par protocole, pastille d'état | fait |
| Navigateur SFTP **à gauche**, lié à l'onglet SSH, « Follow terminal folder » | Volet Fichiers (l'ancien inspecteur de droite a disparu). « Suivre le terminal » inchangé | fait |
| Onglet « Home » (bouton maison), sessions récentes | Bouton maison de la barre d'onglets → `HomeView` : connexion rapide, actions, sessions récentes (⇧⌘H) | fait |
| Onglets de session avec icône, menu contextuel | Icône du protocole + pastille d'état, onglet actif souligné, menu Dupliquer / Fermer / Fermer les autres | fait |
| Barre d'état | `StatusBarView` : protocole et cible, état, dossier courant, tunnels actifs, X11, diffusion, compteurs | fait |
| Barre « Remote monitoring » (CPU, RAM, réseau, disque) | — | à faire |
| Dialogue « Session settings » : bandeau d'icônes de protocoles | `HostEditorSheet` garde un sélecteur de protocole classique | à faire |
| Onglets détachables, mode compact / plein écran | — | à faire |

## Décisions

- **Connexion rapide = session enregistrée.** Comme MobaXterm, une cible ouverte par connexion rapide est ajoutée à la
  bibliothèque (racine), ou réutilise l'hôte SSH identique. Raison : un hôte hors bibliothèque n'aurait pas de cycle de
  vie pour son secret du Trousseau (invariant 7). Si l'enregistrement est refusé, rien n'est ouvert.
- **Analyse stricte de la cible** (`QuickConnectTarget`, EscaleCore) : refus de tout ce qui n'est pas un nom, une adresse
  ou une IPv6 entre crochets (espace, caractère de contrôle, tiret initial lu comme option par ssh).
- **Le volet Fichiers n'existe que s'il est choisi** : `SidebarView` ne construit `SFTPSidebarPane` que dans la branche
  `.files`, car le `.task` du navigateur ouvre un canal SFTP (invariant 12). `SFTPFeature.isVisible` est dérivé de
  `AppModel.sidebarTab`.
- **La barre d'état ne sonde rien** : elle n'affiche que de l'état déjà connu (aucune session ouverte pour la remplir).
- **Sessions récentes** : `recents.json` à côté de la bibliothèque, identifiants d'hôtes et dates seulement, 12 entrées,
  lecture tolérante (fichier illisible = liste vide).
- **Accueil par-dessus les onglets** : `Workspace.showsHome` ; les terminaux restent vivants, le terminal masqué perd le
  premier répondeur et le retrouve au retour.
- **Pas de raccourci ⌃chiffre** pour les volets : réservé au terminal et à Mission Control.
- Langue de développement `fr` (`project.yml`) : les libellés fournis par le système suivent le français.

## Suite proposée

1. **Monitoring distant.** Barre sous le terminal SSH (charge, mémoire, disque, débit réseau, utilisateurs). Il faut une
   session exec sur le maître : désactivé par défaut, activé par un bouton (invariants 5, 12, 13 : `batchExecArguments`,
   compte dans `sessionCount`), une seule commande longue plutôt qu'un exec par relevé. Linux d'abord (`/proc`), repli
   silencieux ailleurs.
2. **Dialogue de session.** Bandeau d'icônes de protocoles en tête de `HostEditorSheet`, réglages regroupés en onglets
   (Basique, Avancé, Terminal, Réseau).
3. **Onglets détachables** et glisser d'un onglet vers une nouvelle fenêtre.
4. **Mode compact** : barre d'outils en icônes seules, barre latérale repliée, bascule par un seul raccourci.
5. Navigateur de fichiers : vraies colonnes (Nom, Taille, Date) quand la barre latérale est assez large.
