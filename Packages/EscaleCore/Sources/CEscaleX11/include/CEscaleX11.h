#ifndef CESCALEX11_H
#define CESCALEX11_H

#include <stddef.h>

/* Pilotage du serveur Xquartz integre (EscaleX11.app lance avec --listenonly) par son protocole Mach
 * (mach_startup.defs de xorg-server) : seule partie en C d'Escale, l'API bootstrap/MIG n'existant qu'en C.
 * Le serveur s'enregistre sous le nom bootstrap egal a son CFBundleIdentifier. */

/* 0 si un serveur est enregistre sous `service` (sans attendre), sinon le kern_return_t de bootstrap_look_up. */
int escale_x11_lookup(const char *service);

/* Attend (au plus timeout_ms) que le serveur `service` soit enregistre, puis lui remet `listen_fd`, un socket Unix
 * deja en ecoute : le serveur accepte ensuite les clients X sur ce socket (aucun /tmp/.X11-unix, aucun root).
 * Renvoie 0, ou un code > 0 avec un message francais dans `err`. `listen_fd` reste a fermer par l'appelant. */
int escale_x11_handoff(const char *service, int listen_fd, int timeout_ms, char *err, size_t errlen);

/* Demarre le serveur `service` avec ces arguments et cet environnement. BLOQUE jusqu'a la fin du serveur
 * (la reponse Mach n'arrive qu'a son arret) : a appeler sur un fil dedie. Renvoie le kern_return_t (0 = arret normal). */
int escale_x11_start(const char *service, const char *const *argv, int argc, const char *const *envp, int envc);

#endif
