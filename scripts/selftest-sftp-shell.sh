#!/bin/bash
# Recette du navigateur SFTP en mode shell : sshd local SANS sous-système sftp (cas du serveur PROMETHEUS).
# Même scénario que selftest-sftp.sh ; l'app doit basculer seule sur les commandes exec.
export SHELL_MODE=1
exec "$(dirname "${BASH_SOURCE[0]}")/selftest-sftp.sh" "$@"
