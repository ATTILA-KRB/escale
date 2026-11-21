// Site text (English). Same keys as fr.ts.
import type { Dict } from './fr';
import release from '../release.json';

export const en: Dict = {
  lang: 'en',
  meta: {
    title: 'Escale — free SSH client for Mac',
    description:
      'Terminal, SFTP files, tunnels, multi-execution and a built-in X11 server in a native Mac app. Free, notarized by Apple.',
    locale: 'en_US',
    ogAlt: 'Escale, SSH client for macOS: terminal, Files pane and tunnels in a single window.',
  },
  nav: {
    features: 'Features',
    protocols: 'Protocols',
    security: 'Security',
    faq: 'FAQ',
    more: 'And more',
    download: 'Download',
    otherLang: 'FR',
    otherLangLabel: 'Version française',
    otherHref: '/',
  },
  hero: {
    kicker: 'SSH client for macOS · free',
    title: ['Every connection.', 'One stopover.'],
    lead:
      'Tabbed terminal, SFTP beside the shell, tunnels and multi-execution, in a native Mac app built on your system’s OpenSSH.',
    cta: 'Download for macOS',
    meta: [`Version ${release.version}`, 'macOS 15 or later', 'Apple silicon and Intel', `${release.sizeMB} MB`],
    callouts: [
      { label: 'SFTP files', href: '#sftp', x: 11, y: 63 },
      { label: 'Tabs and panes', href: '#more', x: 80, y: 10 },
      { label: 'Monitoring', href: '#more', x: 87, y: 53 },
      { label: 'Colored output', href: '#more', x: 78, y: 74 },
    ],
    shotAlt:
      'Escale window: three tabs open, the web-01 server split into two terminals (nginx status, highlighted log), server monitoring under each pane and a Files pane that follows the terminal’s folder.',
  },
  features: {
    title: 'A sysadmin’s workbench, tidied into one window',
    items: [
      {
        id: 'sftp',
        label: 'Files',
        title: 'Server files, right next to the shell',
        body:
          'The Files pane opens the server over the connection you already have: no second login. It follows the terminal’s folder, takes drag and drop from Finder, and sends a locally edited file back as soon as you save it.',
        points: ['Follows the terminal folder', 'Transfer queue, server-to-server copy', 'Shell fallback when the server has no SFTP'],
        shot: 'sftp',
      },
      {
        id: 'tunnels',
        label: 'Tunnels',
        title: 'Tunnels that tell the truth',
        body:
          'Local, remote and SOCKS forwards opened on the live connection. Escale probes the port before showing “active”: a tunnel the server refused never passes for open.',
        points: ['Local, remote, dynamic (SOCKS)', 'IPv6, server-assigned port', 'Edit while running, copy the URL'],
        shot: 'tunnels',
      },
      {
        id: 'multiexec',
        label: 'Multi-exec',
        title: 'Type once, reach ten servers',
        body:
          'Broadcast your typing to every pane of a tab, every tab or a selection, under a red border you can’t miss. Or run one command on a group of hosts and read each exit code.',
        points: ['Broadcast keystrokes and paste', 'Parallel group execution', 'Output, exit code and duration per host'],
        shot: 'multiexec',
      },
      {
        id: 'x11',
        label: 'X11',
        title: 'An X11 server already inside',
        body:
          'Run a remote graphical app without installing XQuartz or typing an admin password. The server starts on demand, listens on no network port, and its windows get a macOS title bar.',
        points: ['Nothing else to install', 'Untrusted mode by default', 'Stopped when Escale quits'],
        shot: 'x11',
      },
    ],
  },
  // Tiles: same ids/order as fr.ts.
  more: {
    title: 'And everything you expect from a complete client',
    items: [
      { id: 'monitoring', wide: true, t: 'Monitoring', d: 'Server CPU, memory, load, disk and throughput under the terminal. Nothing is left on the server.', alt: 'Monitoring bar under the terminal: server CPU, memory, load, disk, network throughput, users and uptime.' },
      { id: 'reconnect', wide: false, t: 'Reconnect', d: 'After a drop, the session comes back in the same tab, screen and scrollback intact.', alt: 'Tab reconnecting after a drop, terminal scrollback kept.' },
      { id: 'macros', wide: false, t: 'Macros', d: 'Record a keystroke sequence, replay it with ⌃⌥1 to 9, on one pane or all of them.', alt: 'Macros pane: “Déployer l’app” on ⌃⌥1, “Espace disque” on ⌃⌥2, and a host-specific macro.' },
      { id: 'quickconnect', wide: false, t: 'Quick connect', d: '⇧⌘K, user@host:port, and the host joins your library.', alt: 'Quick-connect field above the host library, sorted into folders: Infra, Préprod, Production.' },
      { id: 'import', wide: false, t: 'Import', d: 'Bring your MobaXterm, PuTTY or Termius sessions, or your ~/.ssh/config.', alt: 'Tools pane: import sessions from ~/.ssh/config, MobaXterm, PuTTY, Termius or a CSV.' },
      { id: 'colors', wide: true, t: 'Themes and highlighting', d: 'Seven terminal themes (Solarized, Dracula, Tango…) and output highlighting: errors in red, warnings in yellow, IP addresses and URLs in colour.', alt: 'Terminal in the Dracula theme: in the log, ERROR in red, WARNING in yellow, successes in green.' },
      { id: 'panes', wide: false, t: 'Tabs and panes', d: 'Split, detach a tab into its own window, switch to compact mode.', alt: 'The web-01 tab split into two panes, each with its own monitoring bar, beside the db-primary and bastion tabs.' },
    ],
  },
  protocols: {
    title: 'Departures',
    lead: 'One address book for all your equipment.',
    cols: ['Protocol', 'Port', 'In Escale'],
    rows: [
      { p: 'SSH', port: '22', d: 'Terminal, files, tunnels, X11' },
      { p: 'Telnet', port: '23', d: 'Terminal, optional SSH tunnel' },
      { p: 'Serial', port: 'cu.*', d: 'Speed, parity, BREAK, DTR and RTS' },
      { p: 'VNC', port: '5900', d: 'Built-in client, over SSH if needed' },
      { p: 'RDP', port: '3389', d: 'Opens in Windows App, SSH tunnel' },
    ],
  },
  security: {
    title: 'Your OpenSSH, your keys, your Mac',
    items: [
      {
        t: 'Your system’s OpenSSH',
        d: 'Escale drives /usr/bin/ssh: your ~/.ssh/config, ProxyJump and SSH agents work as they are. Escale never writes to ~/.ssh.',
      },
      {
        t: 'Secrets in the Keychain',
        d: 'A password is saved only after a successful login, in the macOS Keychain, never in a file or a log.',
      },
      {
        t: 'Changed host key = refused',
        d: 'If a server’s key changes, the connection is refused. Escale never presents it as a mere confirmation.',
      },
      {
        t: 'No account, no telemetry',
        d: 'Apart from your own connections, Escale only contacts its update feed.',
      },
    ],
  },
  download: {
    title: 'Free. No account. No subscription.',
    lead: 'Open the disk image, drag Escale to Applications. Updates then arrive on their own.',
    cta: `Download Escale ${release.version}`,
    file: `${release.dmg} · ${release.sizeMB} MB`,
    specs: [
      ['System', 'macOS 15 Sequoia or later'],
      ['Processor', 'Apple silicon and Intel (universal)'],
      ['Signature', 'Developer ID, notarized by Apple'],
      ['Updates', 'Built into the app, signed'],
    ],
    note: 'Direct distribution: Escale is not on the Mac App Store because it uses your system’s OpenSSH.',
  },
  support: {
    nav: 'Support',
    navLabel: 'Support Escale: buy me a coffee (new tab)',
    hero: 'Buy me a coffee?',
    lead: 'Does Escale save you time?',
    cta: 'Buy me a coffee',
    footer: 'Support the project',
    thanks: 'Download started. Is Escale useful to you?',
    close: 'Close',
  },
  faq: {
    title: 'FAQ',
    items: [
      { q: 'Is Escale really free?', a: 'Yes. No account, no subscription, no trial: download the app and use it. If you want to say thanks, a coffee is welcome, with nothing expected in return.' },
      {
        q: 'Why not the Mac App Store?',
        a: 'The Mac App Store requires the sandbox, which rules out your system’s OpenSSH and your ~/.ssh/config. Escale is Developer ID signed and notarized by Apple: Gatekeeper checks its origin on first launch.',
      },
      {
        q: 'Coming from MobaXterm — will I feel at home?',
        a: 'The layout is the same: button bar, Sessions and Files panes on the left, home page, status bar. Your sessions import, and the Mac conventions stay.',
      },
      {
        q: 'Where are my passwords stored?',
        a: 'In the macOS Keychain, and only after a successful login. The session library only holds references.',
      },
    ],
  },
  footer: {
    line: 'Escale, SSH client for macOS.',
    legal: 'Legal notice',
    privacy: 'Privacy',
    mockup: 'Mockup — download links not wired yet.',
  },
  dock: {
    home: 'Home',
    features: 'Features',
    protocols: 'Protocols',
    security: 'Security',
    download: 'Download',
  },
  shots: {
    sftp: 'Files pane beside the terminal: it follows the shell’s /var/www/app folder and lists files with size, date and permissions.',
    tunnels: 'Tunnel manager: four bastion forwards active (PostgreSQL, Redis, Grafana, SOCKS proxy); on web-01, a tunnel refused by the server is flagged as failed with its error message.',
    multiexec: 'Group run on the web tag: web-01 and web-02 reply with exit code 0, staging-web, unreachable, is flagged as failed.',
    x11: 'Remote graphical app shown in a macOS window.',
  },
  zoom: { open: 'Enlarge screenshot', close: 'Close preview' },
};
