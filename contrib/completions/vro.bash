# Bash completion for vro — file arguments only.
_vro() {
  local cur
  cur=${COMP_WORDS[COMP_CWORD]}
  mapfile -t COMPREPLY < <(compgen -f -- "$cur")
}
complete -F _vro vro
