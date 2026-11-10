import EscaleCore
import Foundation

// Exécutable SSH_ASKPASS minimal : toute la logique vit dans EscaleCore.
AskpassClient.runIfRequested()
// Variables d'environnement absentes : ce programme n'a pas de raison d'être lancé à la main.
exit(2)
