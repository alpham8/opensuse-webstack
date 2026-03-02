#!/usr/bin/env bash
# Server prompt: [exit-code] hostname:directory > time #/$
#
# Examples:
#   example:/root > 04:30:15 #            (root, normal)
#   [127] example:~/scripts > 04:30:20 #   (root, after error)
#   example:~ > 04:30:25 $                 (user, normal)

[ -z "$BASH_VERSION" ] && return
[ ! -t 1 ] && return   # no terminal (SFTP, SCP, rsync) — skip output

__build_prompt() {
    local ec=$?
    local R='\[\e[0m\]'
    local B='\[\e[1;34m\]'    # bold blue  (directory)
    local G='\[\e[0;32m\]'    # green      (time)
    local D='\[\e[0;90m\]'    # dim gray   (hostname)
    local E='\[\e[1;31m\]'    # bold red   (error / root #)

    PS1=''
    [ $ec -ne 0 ] && PS1+="${E}[${ec}]${R} "
    PS1+="${D}\h${R}:${B}\w${R} > ${G}\t${R} "
    [ "$EUID" -eq 0 ] && PS1+="${E}#${R} " || PS1+='$ '
}

PROMPT_COMMAND=__build_prompt
