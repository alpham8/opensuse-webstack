#!/usr/bin/env bash
# Security overview on interactive SSH login
#
# Shows on each login:
#   - Failed SSH attempts since the last successful login
#   - Number of unique attacker IPs + top attacker
#   - Active CrowdSec and fail2ban bans

[ -z "$BASH_VERSION" ] && return
[[ $- != *i* ]] && return

__login_security() {
    local since label log failed ips top_line top_n top_ip cs f2b

    # Determine previous successful login
    local accepted
    accepted=$(journalctl -u sshd --since "30 days ago" -q --no-pager -o short-iso 2>/dev/null \
        | grep -E "Accepted (publickey|password)")

    if [ "$(printf '%s' "$accepted" | grep -c .)" -ge 2 ]; then
        since=$(printf '%s' "$accepted" | tail -2 | head -1 | awk '{print $1}')
        label="since last login"
    else
        since="24 hours ago"
        label="last 24h"
    fi

    # Failed SSH attempts
    log=$(journalctl -u sshd --since "$since" -q --no-pager -o cat 2>/dev/null \
        | grep -E "Failed password|Invalid user")

    if [ -n "$log" ]; then
        failed=$(printf '%s\n' "$log" | wc -l)
        ips=$(printf '%s\n' "$log" | grep -oP 'from \K[\d.]+' | sort -u | wc -l)
        top_line=$(printf '%s\n' "$log" | grep -oP 'from \K[\d.]+' | sort | uniq -c | sort -rn | head -1)
        top_n=$(echo "$top_line" | awk '{print $1}')
        top_ip=$(echo "$top_line" | awk '{print $2}')
    else
        failed=0 ips=0
    fi

    # Active bans (only real bans, no whitelists)
    cs=$(cscli decisions list -o raw 2>/dev/null | awk -F, 'NR>1 && $5=="ban"' | wc -l)
    f2b=$(fail2ban-client status sshd 2>/dev/null | awk '/Currently banned/{print $NF}')

    printf '\n\e[0;90m── Security (%s) ──\e[0m\n' "$label"
    printf '  Failed SSH logins:           \e[1;33m%d\e[0m' "$failed"
    [ "$failed" -gt 0 ] && printf '  (%d IPs)' "$ips"
    printf '\n'
    [ "$failed" -gt 0 ] && [ -n "$top_ip" ] && \
        printf '  Top attacker:                \e[1;33m%s\e[0m (%dx)\n' "$top_ip" "$top_n"
    printf '  CrowdSec bans active:        \e[1;33m%d\e[0m\n' "${cs:-0}"
    printf '  fail2ban SSH bans:           \e[1;33m%d\e[0m\n' "${f2b:-0}"
    printf '\e[0;90m───────────────────────────────────────────\e[0m\n\n'
}

__login_security
unset -f __login_security
