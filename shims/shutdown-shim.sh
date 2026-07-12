#!/bin/bash
# =============================================================================
# Shim shutdown – convertit tout appel "shutdown ..." en redémarrage
#
# Installé dans /usr/local/sbin/shutdown. Que l'appel soit
# "shutdown -h now", "shutdown -P" ou "shutdown -r now", le résultat est
# toujours un redémarrage : on ne coupe jamais réellement l'alimentation
# depuis une application de la borne.
# =============================================================================
set -u

LOG="/var/log/kiosk-menu/shutdown-guard.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
echo "$(date '+%F %T') [shutdown] appel intercepté : shutdown $* -> reboot" >> "$LOG" 2>/dev/null || true

REAL_SYSTEMCTL=""
for candidate in /usr/bin/systemctl /bin/systemctl; do
    if [[ -x "$candidate" ]]; then
        REAL_SYSTEMCTL="$candidate"
        break
    fi
done

if [[ -n "$REAL_SYSTEMCTL" ]]; then
    exec "$REAL_SYSTEMCTL" reboot
fi

for candidate in /usr/sbin/reboot /sbin/reboot; do
    if [[ -x "$candidate" ]]; then
        exec "$candidate"
    fi
done

exit 1
