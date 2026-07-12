#!/bin/bash
# =============================================================================
# Shim systemctl – convertit uniquement "systemctl poweroff/halt/..." en
# reboot, et laisse passer TOUTES les autres commandes vers le vrai
# systemctl (start/stop/enable/status/etc. continuent de fonctionner
# normalement, y compris pour clamav, libvirtd, etc.)
#
# Installé dans /usr/local/bin/systemctl (prioritaire dans le PATH).
# =============================================================================
set -u

LOG="/var/log/kiosk-menu/shutdown-guard.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

REAL_SYSTEMCTL=""
for candidate in /usr/bin/systemctl /bin/systemctl; do
    if [[ -x "$candidate" ]]; then
        REAL_SYSTEMCTL="$candidate"
        break
    fi
done

if [[ -z "$REAL_SYSTEMCTL" ]]; then
    echo "systemctl réel introuvable" >&2
    exit 1
fi

# Recherche le premier argument qui n'est pas une option (ne commence pas par '-')
ACTION=""
for arg in "$@"; do
    case "$arg" in
        -*) continue ;;
        *)  ACTION="$arg"; break ;;
    esac
done

case "$ACTION" in
    poweroff|power-off|halt|hibernate|hybrid-sleep|suspend)
        echo "$(date '+%F %T') [systemctl] appel intercepté : systemctl $* -> reboot" >> "$LOG" 2>/dev/null || true
        exec "$REAL_SYSTEMCTL" reboot
        ;;
    *)
        exec "$REAL_SYSTEMCTL" "$@"
        ;;
esac
