# Fichier --rcfile du faux shell interactif : invite façon Ubuntu (couleur), historique désactivé.
# Aliases de vfuncs.sh : les alias ne sont développés qu'en interactif, d'où `shopt -s expand_aliases` implicite ici.
. "$LABSRC/vfuncs.sh"
set +o history
unset HISTFILE
# \u et \h viendraient de getpwuid/gethostname (vrai utilisateur, vraie machine) : valeurs littérales.
PS1="\[\e[01;32m\]deploy@${LABHOST}\[\e[00m\]:\[\e[01;34m\]\$(_vp)\[\e[00m\]\\$ "
unset PROMPT_COMMAND
export PS1
