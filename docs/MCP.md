# Accès des agents IA (MCP)

Escale est un **serveur MCP** (Model Context Protocol) local : un agent IA (Claude Code, Cursor, Claude Desktop,
Hermes…) peut agir sur vos hôtes SSH à travers les connexions que vous avez déjà ouvertes dans Escale. L'agent
ne se connecte jamais lui-même : les authentifications (mot de passe, 2FA, bastions) restent les vôtres.

## Activer

1. Menu **Présentation › Accès des agents (MCP)…**, puis cochez « Autoriser l'accès des agents ».
2. Dans la fiche de chaque hôte SSH à exposer (onglet **Avancé**), réglez **Accès des agents (MCP)** :

| Niveau | Lecture (hôtes, sessions, terminal, fichiers, tunnels) | Actions (commande, saisie, écriture, tunnel) |
|---|---|---|
| Aucun (défaut) | hôte invisible | — |
| Lecture seule | oui | refusées |
| Actions avec confirmation | oui | panneau de confirmation pour chaque action |
| Actions sans confirmation | oui | sans demander (journalisées) |

3. Déclarez Escale dans le client (les deux commandes sont copiables depuis la fenêtre des réglages) :

```sh
claude mcp add escale -- /Applications/Escale.app/Contents/MacOS/Escale --mcp
```

```json
{ "mcpServers": { "escale": { "command": "/Applications/Escale.app/Contents/MacOS/Escale", "args": ["--mcp"] } } }
```

`Escale --mcp` est un relais stdio vers l'app en service : il ne lance pas Escale et échoue (code 1, message sur stderr)
si l'app est fermée ou l'accès désactivé.

## Outils

| Outil | Nature | Rôle |
|---|---|---|
| `list_hosts` | lecture | hôtes exposés : id, nom, adresse, utilisateur, niveau, état de connexion |
| `list_sessions` | lecture | panneaux de terminal ouverts sur ces hôtes |
| `read_terminal` | lecture | dernières lignes d'un panneau (écran + historique) |
| `send_input` | action | saisie dans un panneau, comme au clavier (caractères de contrôle permis) |
| `exec` | action | commande non interactive (sans pty, BatchMode, sans X11) : code, stdout, stderr |
| `list_files`, `read_file` | lecture | SFTP (repli shell si le serveur refuse SFTP) ; binaire rendu en base64 |
| `write_file` | action | crée ou remplace un fichier (4 Mio au plus) |
| `list_tunnels` | lecture | tunnels enregistrés de l'hôte et leur état |
| `start_tunnel`, `stop_tunnel` | action | ouvre/ferme un tunnel enregistré (vérifié par sonde du port) |

## Sécurité

- Désactivé par défaut. Aucune écoute TCP : socket Unix `~/Library/Application Support/Escale/agent/mcp.sock` (0600,
  dossier 0700), pair vérifié (même uid, des deux côtés).
- Aucun hôte hors bibliothèque ; protocoles non SSH jamais exposés ; aucun secret dans les réponses (ni mot de passe,
  ni compte Trousseau, ni chemin de clé).
- Un agent n'ouvre jamais de connexion : un hôte déconnecté renvoie une erreur (« ouvrez-le dans Escale »).
- Les sorties distantes sont des données non fiables (injection de prompt) : c'est la raison du niveau « avec
  confirmation ». Le panneau de confirmation flotte au-dessus des autres apps sans prendre le focus ; une demande
  disparaît si le client se déconnecte.
- Journal en mémoire de chaque appel (outil, hôte, résumé, issue), visible dans la fenêtre des réglages ; jamais écrit
  sur disque, jamais de contenu de fichier ni de sortie.
- Bornes : commande 600 s et 1 Mio de sortie, lecture/écriture 4 Mio, saisie 64 Kio, 8 clients, 16 appels simultanés
  par client, au plus 10 sessions par maître (les appels passent par le plafond commun).
