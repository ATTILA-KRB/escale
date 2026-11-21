// Texte du site (français, langue par défaut). Chaque affirmation se vérifie dans docs/PLAN.md ou le code de l'app.
// Version publiée : release.json, écrit par scripts/publish.sh (ne pas l'inscrire en dur ici).
import release from '../release.json';
export const fr = {
  lang: 'fr',
  meta: {
    title: 'Escale — client SSH gratuit pour Mac',
    description:
      'Terminal, fichiers SFTP, tunnels, multi-exécution et serveur X11 intégré dans une app Mac native. Gratuit, notarisé par Apple.',
    locale: 'fr_FR',
    ogAlt: 'Escale, client SSH pour macOS : terminal, volet Fichiers et tunnels dans une seule fenêtre.',
  },
  nav: {
    features: 'Fonctions',
    protocols: 'Protocoles',
    security: 'Sécurité',
    faq: 'Questions',
    more: 'Et aussi',
    download: 'Télécharger',
    otherLang: 'EN',
    otherLangLabel: 'English version',
    otherHref: '/en',
  },
  hero: {
    kicker: 'Client SSH pour macOS · gratuit',
    title: ['Toutes vos connexions.', 'Une seule escale.'],
    lead:
      'Terminal à onglets, SFTP à côté du shell, tunnels et multi-exécution, dans une app Mac native qui s’appuie sur l’OpenSSH de votre système.',
    cta: 'Télécharger pour macOS',
    meta: [`Version ${release.version}`, 'macOS 15 ou plus', 'Apple Silicon et Intel', `${release.sizeMB} Mo`],
    // Repères posés sur la capture (md et plus) : x et y en % de l’image (volet Fichiers, bouton MultiExec, barre de monitoring, journal coloré).
    callouts: [
      { label: 'Fichiers SFTP', href: '#sftp', x: 11, y: 63 },
      { label: 'Onglets et panneaux', href: '#more', x: 80, y: 10 },
      { label: 'Monitoring', href: '#more', x: 87, y: 53 },
      { label: 'Sortie colorée', href: '#more', x: 78, y: 74 },
    ],
    shotAlt:
      'Fenêtre d’Escale : trois onglets ouverts, le serveur web-01 scindé en deux terminaux (état de nginx, journal coloré), monitoring du serveur sous chaque panneau et volet Fichiers qui suit le dossier du terminal.',
  },
  features: {
    title: 'Le poste de travail d’un admin, rangé dans une fenêtre',
    items: [
      {
        id: 'sftp',
        label: 'Fichiers',
        title: 'Les fichiers du serveur, à côté du shell',
        body:
          'Le volet Fichiers ouvre le serveur sur la connexion déjà établie : pas de seconde authentification. Il suit le dossier du terminal, accepte le glisser-déposer depuis le Finder et renvoie un fichier édité en local dès que vous l’enregistrez.',
        points: [
          'Suivi du dossier du terminal',
          'File de transferts, copie d’un serveur à l’autre',
          'Repli par le shell quand le serveur n’offre pas SFTP',
        ],
        shot: 'sftp',
      },
      {
        id: 'tunnels',
        label: 'Tunnels',
        title: 'Des tunnels qui disent la vérité',
        body:
          'Redirections locales, distantes et SOCKS ouvertes sur la connexion en cours. Escale sonde le port avant d’afficher « actif » : un tunnel refusé par le serveur ne passe jamais pour ouvert.',
        points: ['Local, distant, dynamique (SOCKS)', 'IPv6, port attribué par le serveur', 'Modification à chaud, URL à copier'],
        shot: 'tunnels',
      },
      {
        id: 'multiexec',
        label: 'Multi-exécution',
        title: 'Une frappe, dix serveurs',
        body:
          'Diffusez la saisie vers les panneaux d’un onglet, vers tous les onglets ou vers une sélection, sous une bordure rouge impossible à oublier. Ou lancez une commande sur un groupe d’hôtes et lisez le code de retour de chacun.',
        points: ['Diffusion des frappes et du collage', 'Exécution groupée en parallèle', 'Sortie, code et durée par hôte'],
        shot: 'multiexec',
      },
      {
        id: 'x11',
        label: 'X11',
        title: 'Un serveur X11 déjà dans l’app',
        body:
          'Lancez une application graphique distante sans installer XQuartz ni taper de mot de passe administrateur. Le serveur démarre à la demande, n’écoute aucun port réseau et ses fenêtres prennent une barre de titre macOS.',
        points: ['Aucune installation séparée', 'Mode non fiable par défaut', 'Arrêté à la fermeture d’Escale'],
        shot: 'x11',
      },
    ],
  },
  // Tuiles « Et tout ce qu’on attend » : `id` = nom de la capture tile-<id>.png (si elle existe), `wide` = tuile élargie.
  more: {
    title: 'Et tout ce qu’on attend d’un client complet',
    items: [
      { id: 'monitoring', wide: true, t: 'Monitoring', d: 'CPU, mémoire, charge, disque et débit du serveur sous le terminal. Rien n’est déposé sur le serveur.', alt: 'Barre de monitoring sous le terminal : CPU, mémoire, charge, disque, débit réseau, utilisateurs et durée de fonctionnement du serveur.' },
      { id: 'reconnect', wide: false, t: 'Reconnexion', d: 'Après une coupure, la session revient dans le même onglet, écran et historique conservés.', alt: 'Onglet qui se reconnecte après une coupure, avec l’historique du terminal conservé.' },
      { id: 'macros', wide: false, t: 'Macros', d: 'Enregistrez une suite de frappes, rejouez-la avec ⌃⌥1 à 9, sur un panneau ou sur tous.', alt: 'Volet Macros : « Déployer l’app » sur ⌃⌥1, « Espace disque » sur ⌃⌥2, et une macro propre à l’hôte.' },
      { id: 'quickconnect', wide: false, t: 'Connexion rapide', d: '⇧⌘K, utilisateur@hôte:port, et l’hôte rejoint votre bibliothèque.', alt: 'Champ de connexion rapide au-dessus de la bibliothèque d’hôtes classés par dossier : Infra, Préprod, Production.' },
      { id: 'import', wide: false, t: 'Import', d: 'Reprenez vos sessions MobaXterm, PuTTY, Termius ou votre ~/.ssh/config.', alt: 'Volet Outils : import des sessions depuis ~/.ssh/config, MobaXterm, PuTTY, Termius ou un CSV.' },
      { id: 'colors', wide: true, t: 'Thèmes et coloration', d: 'Sept thèmes de terminal (Solarized, Dracula, Tango…) et surlignage de la sortie\u00a0: erreurs en rouge, avertissements en jaune, adresses IP et URL en couleur.', alt: 'Terminal en thème Dracula : dans le journal, ERROR en rouge, WARNING en jaune, réussites en vert.' },
      { id: 'panes', wide: false, t: 'Onglets et panneaux', d: 'Scindez, détachez un onglet dans sa propre fenêtre, passez en mode compact.', alt: 'Onglet web-01 scindé en deux panneaux, chacun avec sa barre de monitoring, à côté des onglets db-primary et bastion.' },
    ],
  },
  protocols: {
    title: 'Départs',
    lead: 'Un seul carnet d’adresses pour tous vos équipements.',
    cols: ['Protocole', 'Port', 'Dans Escale'],
    rows: [
      { p: 'SSH', port: '22', d: 'Terminal, fichiers, tunnels, X11' },
      { p: 'Telnet', port: '23', d: 'Terminal, option tunnel SSH' },
      { p: 'Série', port: 'cu.*', d: 'Débit, parité, BREAK, DTR et RTS' },
      { p: 'VNC', port: '5900', d: 'Client intégré, via SSH si besoin' },
      { p: 'RDP', port: '3389', d: 'Ouvert dans Windows App, tunnel SSH' },
    ],
  },
  security: {
    title: 'Votre OpenSSH, vos clés, votre Mac',
    items: [
      {
        t: 'L’OpenSSH du système',
        d: 'Escale pilote /usr/bin/ssh : vos réglages ~/.ssh/config, ProxyJump et agents SSH fonctionnent tels quels. Escale n’écrit jamais dans ~/.ssh.',
      },
      {
        t: 'Secrets dans le Trousseau',
        d: 'Un mot de passe n’est enregistré qu’après une connexion réussie, dans le Trousseau macOS, jamais dans un fichier ni dans un journal.',
      },
      {
        t: 'Clé d’hôte modifiée = refus',
        d: 'Si la clé d’un serveur change, la connexion est refusée. Escale ne la présente pas comme une simple confirmation.',
      },
      {
        t: 'Aucun compte, aucune télémétrie',
        d: 'Hors de vos connexions, Escale ne contacte que son flux de mises à jour.',
      },
    ],
  },
  download: {
    title: 'Gratuit. Sans compte. Sans abonnement.',
    lead: 'Ouvrez l’image disque, glissez Escale dans Applications. Les mises à jour arrivent ensuite d’elles-mêmes.',
    cta: `Télécharger Escale ${release.version}`,
    file: `${release.dmg} · ${release.sizeMB} Mo`,
    specs: [
      ['Système', 'macOS 15 Sequoia ou plus récent'],
      ['Processeur', 'Apple Silicon et Intel (universel)'],
      ['Signature', 'Developer ID, notarisée par Apple'],
      ['Mises à jour', 'Intégrées à l’app, signées'],
    ],
    note: 'Distribution directe : Escale n’est pas sur le Mac App Store, car il utilise l’OpenSSH de votre système.',
  },
  support: {
    nav: 'Soutenir',
    navLabel: 'Soutenir Escale : offrez-moi un café (nouvel onglet)',
    hero: 'Un café pour remercier ?',
    lead: 'Escale vous fait gagner du temps ?',
    cta: 'Offrez-moi un café',
    footer: 'Soutenir le projet',
    thanks: 'Téléchargement lancé. Escale vous rend service ?',
    close: 'Fermer',
  },
  faq: {
    title: 'Questions',
    items: [
      {
        q: 'Escale est-il vraiment gratuit ?',
        a: 'Oui. Ni compte, ni abonnement, ni période d’essai : vous téléchargez l’app et vous l’utilisez. Si vous voulez remercier, un café est le bienvenu, sans aucune contrepartie.',
      },
      {
        q: 'Pourquoi pas le Mac App Store ?',
        a: 'Le Mac App Store impose la sandbox, incompatible avec l’OpenSSH du système et votre ~/.ssh/config. Escale est signé Developer ID et notarisé par Apple : Gatekeeper vérifie son origine à la première ouverture.',
      },
      {
        q: 'Je viens de MobaXterm, je retrouve mes repères ?',
        a: 'La disposition est la même : barre de boutons, volets Sessions et Fichiers à gauche, page d’accueil, barre d’état. Vos sessions s’importent, dans le respect des conventions du Mac.',
      },
      {
        q: 'Où sont stockés mes mots de passe ?',
        a: 'Dans le Trousseau macOS, et seulement après une connexion réussie. La bibliothèque de sessions ne contient que des références.',
      },
    ],
  },
  footer: {
    line: 'Escale, client SSH pour macOS.',
    legal: 'Mentions légales',
    privacy: 'Confidentialité',
    mockup: 'Maquette — liens de téléchargement non branchés.',
  },
  dock: {
    home: 'Accueil',
    features: 'Fonctions',
    protocols: 'Protocoles',
    security: 'Sécurité',
    download: 'Télécharger',
  },
  shots: {
    sftp: 'Volet Fichiers ouvert à côté du terminal : il suit le dossier /var/www/app du shell et liste les fichiers avec taille, date et droits.',
    tunnels: 'Gestionnaire de tunnels : quatre redirections du bastion actives (PostgreSQL, Redis, Grafana, proxy SOCKS) ; sur web-01, un tunnel refusé par le serveur est signalé en échec avec son message d’erreur.',
    multiexec: 'Exécution groupée sur l’étiquette web : web-01 et web-02 répondent avec le code 0, staging-web, injoignable, est signalé en échec.',
    x11: 'Application graphique distante affichée dans une fenêtre macOS.',
  },
  zoom: { open: 'Agrandir la capture', close: 'Fermer l’aperçu' },
};

export type Dict = typeof fr;
