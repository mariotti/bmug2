#! /bin/bash
#
# bash completion for the bmu dispatcher. Static subcommand names only -
# no dynamic project-name completion (e.g. for archive/unarchive), since
# that would need to re-locate and source backmeup.setup.sh on every TAB
# press, kept fast and without assuming any bmug2 env vars are set. See
# docs/MANUAL.md for that as a documented future enhancement.
#
# Activate with:
#   . "path/to/bmu-completion.bash"
#
_bmu_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local subs="backup status locate archive unarchive migrate updatedb -n --dry-run"
    COMPREPLY=( $(compgen -W "${subs}" -- "${cur}") )
}
complete -F _bmu_complete bmu
