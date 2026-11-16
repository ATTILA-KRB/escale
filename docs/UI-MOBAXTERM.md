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
| Barre « Remote monitoring » (CPU, RAM, réseau, disque) | `Escale/Monitoring/` : barre sous le panneau SSH (CPU, mémoire, charge, disque, débit, utilisateurs, uptime), réglage par hôte, ⌥⌘U | fait |
| Dialogue « Session settings » : bandeau d'icônes de protocoles | `HostEditorSheet` : bandeau SSH/Telnet/Série/VNC/RDP, onglets Basique/Avancé/Terminal/Réseau (ou réglages du protocole) | fait |
| Onglets détachables | `DetachedWindows` : Détacher / Ramener (menus), même moteur et même pty ; glisser hors de la barre non fait | fait (partiel) |
| Bouton barre latérale | Item « Barre latérale » de `MainToolbar` (tête de barre, personnalisable) + menu Présentation ⌃⌘S ; bouton système retiré | fait |
| Mode compact | `CompactMode` : icônes seules, barre latérale repliée, barre d'état réduite, ⇧⌘M, persistant | fait |
| Navigateur de fichiers en colonnes | `SFTPColumns` : Nom/Taille/Date dès 430 pt, + Droits dès 540 pt (hystérésis 24 pt), en-têtes triables | fait |

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
- **Monitoring = réglage de l'hôte**, pas du panneau : il suit les nouveaux panneaux et les reconnexions. Une session
  exec longue par panneau (`openShellStream`, BatchMode sans X11), script POSIX sh en argument (rien déposé côté
  serveur), un bloc toutes les 2 s ; maître plein = rien ouvert, barre « maître plein ». Débit : interfaces physiques
  seules (bouclage, ponts, veth, docker, tunnels écartés, sinon double compte).
- **Mode compact** : choisir un volet rouvre temporairement la barre latérale (sinon le choix serait invisible) ;
  elle se replie à l'ouverture d'un onglet. Le mode de la barre d'outils d'avant est restauré en sortie.
- **Bannière du terminal local** (`WelcomeBanner`, cœur) : logo « ESCALE » en blocs, dégradé jaune doré → orangé
  en couleurs 24 bits (la palette 256 de SwiftTerm rend ces jaunes ternes), puis un cadre version / shell / raccourcis.
  Écrite dans l'écran du moteur avant le shell (jamais envoyée au shell), au premier lancement seulement, pas pour une
  commande explicite ; titre sur une ligne et sans cadre si l'écran est trop étroit. Aucun nom d'utilisateur ni de
  machine. Absente des recettes sauf `--local-banner on` ; `escale.localBanner = NO` la coupe.
- **Onglet détaché** : seul l'hébergement de la vue change (`TerminalTab.windowID`) ; l'onglet reste dans
  `Workspace.tabs` (compteurs, multi-exécution, macros le voient), moteur et pty jamais recréés.

## Couleurs du terminal

Équivalent de la « coloration syntaxique » et des thèmes de MobaXterm (`Escale/Colors/`, modèles dans
`EscaleCore/Terminal/{TerminalTheme,OutputHighlighter}.swift`) :
- **Thèmes** (Présentation › Thème du terminal, réglage général) : Système, Classique (fond noir, proche de MobaXterm), Tango sombre,
  Solarized sombre et clair, Dracula, Papier. Palette ANSI 16 couleurs (le cube 256 en dérive), texte, fond (marges et séparateurs compris),
  curseur, sélection. Appliqué aux panneaux ouverts et à tout nouveau panneau avant son premier octet.
- **Coloration de la sortie** (Présentation › Coloration de la sortie ; remplaçable par hôte dans son menu contextuel) :
  Désactivé, Mots-clés (défaut : erreur/échec rouge, avertissement jaune, ok/succès vert, FR et EN), Mots-clés et réseau
  (plus IPv4 magenta, URL bleues). Seules des séquences SGR sont insérées ; écran alternatif (vim, less, htop) et texte
  déjà coloré par le programme laissés intacts ; mot coupé entre deux paquets retenu au plus 8 ms (aucune attente sur
  l'écho d'une frappe).
- Pas encore : règles personnalisées (expressions de l'utilisateur), jeux Cisco/shell, chemins de fichiers.

## Suite proposée

1. **Glisser un onglet hors de la barre** vers une nouvelle fenêtre (pas d'API SwiftUI propre pour un dépôt hors cible :
   passer par `NSDraggingSession` côté AppKit).
2. Monitoring : vérifier un BSD réel (repli macOS seul testé) et l'affichage dans une fenêtre étroite.
