#!/bin/bash
# =============================================================================
# Shim poweroff / halt – convertit toute extinction en redémarrage
#
# Installé dans /usr/local/sbin/{poweroff,halt} (via lien symbolique), donc
# prioritaire dans le PATH par défaut (y compris secure_path de sudo) devant
# les vrais binaires /usr/sbin/{poweroff,halt}.
#
# Les 4 applications (shadowClone, e-Broyeur, VirtuPack, Bastion-Antiviral)
# appellent directement `poweroff` sans chemin absolu : ce shim est donc
# systématiquement exécuté à leur place.
# =============================================================================
set -u

SELF="$(basename "$0")"
LOG="/var/log/kiosk-menu/shutdown-guard.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

echo "$(date '+%F %T') [$SELF] appel intercepté (pid appelant $PPID) -> reboot" >> "$LOG" 2>/dev/null || true

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

# Filet de sécurité si systemctl est introuvable (ne devrait pas arriver sous
# live-build/systemd) : tente les binaires réels de redémarrage directement.
for candidate in /usr/sbin/reboot /sbin/reboot; do
    if [[ -x "$candidate" ]]; then
        exec "$candidate"
    fi
done

echo "$(date '+%F %T') [$SELF] ERREUR : aucun mécanisme de redémarrage trouvé" >> "$LOG" 2>/dev/null || true
exit 1
