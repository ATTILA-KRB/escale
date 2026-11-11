// Remise du socket d'ecoute au serveur Xquartz integre et demarrage (protocole de hw/xquartz/mach-startup/stub.c).
#include "CEscaleX11.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>

#include "mach_startup.h"

static int fail(char *err, size_t errlen, int code, const char *fmt, const char *detail) {
    if (err && errlen) snprintf(err, errlen, fmt, detail ? detail : "");
    return code;
}

static int lookup(const char *service, int timeout_ms, mach_port_t *port) {
    kern_return_t kr = KERN_FAILURE;
    for (int waited = 0; ; waited += 50) {
        kr = bootstrap_look_up(bootstrap_port, service, port);
        if (kr == KERN_SUCCESS || waited >= timeout_ms) break;
        usleep(50 * 1000);
    }
    return kr;
}

int escale_x11_lookup(const char *service) {
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, service, &port);
    if (kr == KERN_SUCCESS) mach_port_deallocate(mach_task_self(), port);
    return kr;
}

int escale_x11_handoff(const char *service, int listen_fd, int timeout_ms, char *err, size_t errlen) {
    mach_port_t port = MACH_PORT_NULL;
    if (lookup(service, timeout_ms, &port) != KERN_SUCCESS)
        return fail(err, errlen, 1, "Le serveur X11 integre ne s'est pas enregistre (%s).", service);

    // Le serveur cree un socket temporaire et l'indique ; on s'y connecte pour lui passer le descripteur (SCM_RIGHTS).
    string_t filename;
    memset(filename, 0, sizeof filename);
    if (request_fd_handoff_socket(port, filename) != KERN_SUCCESS)
        return fail(err, errlen, 2, "Le serveur X11 integre refuse la remise du socket.%s", NULL);

    int c = socket(AF_UNIX, SOCK_STREAM, 0);
    if (c < 0) return fail(err, errlen, 3, "socket : %s", strerror(errno));
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    if (strlcpy(addr.sun_path, filename, sizeof addr.sun_path) >= sizeof addr.sun_path) {
        close(c);
        return fail(err, errlen, 3, "Chemin de remise trop long : %s", filename);
    }
    int connected = -1;
    for (int i = 0; i < 100 && connected != 0; i++) {
        connected = connect(c, (struct sockaddr *)&addr, sizeof addr);
        if (connected != 0) usleep(20 * 1000);
    }
    if (connected != 0) { close(c); return fail(err, errlen, 4, "Connexion au socket de remise impossible : %s", strerror(errno)); }

    char data[] = "display";
    struct iovec iov = { .iov_base = data, .iov_len = sizeof data };
    union { struct cmsghdr hdr; char buf[CMSG_SPACE(sizeof(int))]; } control;
    memset(&control, 0, sizeof control);
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = control.buf, .msg_controllen = sizeof control.buf };
    struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cm), &listen_fd, sizeof(int));
    ssize_t sent = sendmsg(c, &msg, 0);
    int saved = errno;
    close(c);
    if (sent < 0) return fail(err, errlen, 5, "Remise du socket impossible : %s", strerror(saved));
    return 0;
}

int escale_x11_start(const char *service, const char *const *argv, int argc, const char *const *envp, int envc) {
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = lookup(service, 2000, &port);
    if (kr != KERN_SUCCESS) return kr;
    // string_array_t : tableau de string_t (char[1024]) ; une entree plus longue est refusee plutot que tronquee.
    string_t *av = calloc((size_t)argc + 1, sizeof(string_t));
    string_t *ev = calloc((size_t)envc + 1, sizeof(string_t));
    if (!av || !ev) { free(av); free(ev); return KERN_RESOURCE_SHORTAGE; }
    for (int i = 0; i < argc; i++)
        if (strlcpy(av[i], argv[i], sizeof(string_t)) >= sizeof(string_t)) { free(av); free(ev); return KERN_INVALID_ARGUMENT; }
    for (int i = 0; i < envc; i++)
        if (strlcpy(ev[i], envp[i], sizeof(string_t)) >= sizeof(string_t)) { free(av); free(ev); return KERN_INVALID_ARGUMENT; }
    kr = start_x11_server(port, av, (mach_msg_type_number_t)argc, ev, (mach_msg_type_number_t)envc);
    free(av);
    free(ev);
    return kr;
}
