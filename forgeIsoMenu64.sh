#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  forgeIsoMenu64.sh  –  ISO live Debian Trixie – Borne multi-services          ║
# ║                        OpenBox kiosque + Sélecteur de menu                    ║
# ║                                                                                ║
# ║  Fusionne 4 applications indépendantes derrière un seul menu de sélection :   ║
# ║    1. shadowClone         – Cloneur de disque (dd bit-à-bit)                  ║
# ║    2. e-Broyeur           – Effacement sécurisé de disque (HDD/SSD)          ║
# ║    3. VirtuPack           – Conversion Physique → Virtuel (virt-manager)      ║
# ║    4. Bastion-Antiviral   – Scanner antiviral USB (ClamAV + YARA + Avast)     ║
# ║                                                                                ║
# ║  Principe du wrapper :                                                        ║
# ║    - Un menu Tkinter plein écran (menu_selector/main.py) est le point         ║
# ║      d'entrée unique de la session kiosque. Il lance l'appli choisie en       ║
# ║      sous-processus et réaffiche le menu à sa fermeture.                     ║
# ║    - Chaque application dispose de son PROPRE bouton "Redémarrer" (ajouté    ║
# ║      directement dans le code des 4 applications, hors périmètre de ce       ║
# ║      script) pour revenir au menu. Ce wrapper n'intercepte plus aucune        ║
# ║      commande système (aucun shim poweroff/systemctl).                       ║
# ║    - L'extinction RÉELLE de la borne se fait exclusivement depuis le          ║
# ║      panneau d'Administration du menu, protégé par mot de passe               ║
# ║      (/etc/kiosk-menu/admin.pass), via `systemctl poweroff` en chemin        ║
# ║      absolu.                                                                  ║
# ║    - Ce même panneau d'Administration permet d'activer/désactiver chaque     ║
# ║      bouton du menu principal (/etc/kiosk-menu/apps_state.json). Un          ║
# ║      bouton désactivé apparaît grisé et ne lance plus rien au clic.          ║
# ║                                                                                ║
# ║  Spécificités préservées par appli :                                          ║
# ║    - VirtuPack   : qemu.conf (user/group=root) + ACL cgroup pour disques      ║
# ║                    amovibles + service vp-libvirt-setup, pour que             ║
# ║                    virt-manager puisse lancer une VM stockée sur un disque    ║
# ║                    externe (clé USB / disque externe monté en cours de        ║
# ║                    session).                                                 ║
# ║    - e-Broyeur   : AUCUNE règle udev ne force la valeur de                    ║
# ║                    /sys/block/*/queue/rotational. C'est volontaire : la       ║
# ║                    détection mécanique/SSD de e-Broyeur (is_ssd() dans        ║
# ║                    disk_erase.py) lit cet attribut directement et doit        ║
# ║                    rester fiable pour choisir le bon algorithme d'effacement. ║
# ║    - Bastion-Antiviral : hooks ClamAV / YARA / Avast repris tels quels.       ║
# ║    - shadowClone : son code vit dans code_installer/ dans le dépôt amont      ║
# ║                    (pas code/) — c'est le seul des 4 dans ce cas.             ║
# ║                                                                                ║
# ║  Simplifications assumées par rapport aux scripts d'origine :                 ║
# ║    - Un seul mode "Installer sur disque", générique (rsync du système        ║
# ║      live complet : 4 applications + menu + antivirus + libvirt), au lieu    ║
# ║      d'un installateur par application. Le système installé démarre          ║
# ║      directement sur le même menu de sélection (session xfwm4 dédiée).       ║
# ║    - Le pré-check réseau Avast côté machine de build (config/archives) est    ║
# ║      retiré : le hook 0250 (exécuté en chroot) suffit et gère déjà tous les  ║
# ║      cas d'échec réseau proprement.                                          ║
# ║                                                                                ║
# ║  Pré-requis sur la machine de build :                                        ║
# ║    sudo apt install live-build xorriso syslinux git wget curl python3 unzip  ║
# ║    Connexion Internet (clone des 4 dépôts GitHub + dépôts Debian/Avast)      ║
# ║                                                                                ║
# ║  Exécution :                                                                  ║
# ║    chmod +x forgeIsoMenu64.sh && sudo ./forgeIsoMenu64.sh                    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Variables ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)/debian-live-build"
REPOS_DIR="$(pwd)/repos-src"

declare -A REPO_URL=(
    [shadowclone]="https://github.com/Bolo101/shadowClone.git"
    [e-broyeur]="https://github.com/Bolo101/e-Broyeur.git"
    [virtupack]="https://github.com/Bolo101/VirtuPack.git"
    [bastion-antiviral]="https://github.com/Bolo101/Bastion-Antiviral.git"
)

SIGBASE_URL="https://github.com/Neo23x0/signature-base/archive/refs/heads/master.zip"

# ── Sous-dossier de code retenu par application ──────────────────────────────
# shadowClone, e-Broyeur et VirtuPack : leur code utile vit dans
# code_installer/ (panneau admin protégé par mot de passe inclus,
# config_manager, etc.).
# Bastion-Antiviral : son code vit dans code/ (il inclut déjà nativement
# l'authentification via admin_auth.py, il n'y a pas de code_installer/
# séparé dans ce dépôt).
declare -A REPO_CODE_SUBDIR=(
    [shadowclone]="code_installer"
    [e-broyeur]="code_installer"
    [virtupack]="code_installer"
    [bastion-antiviral]="code"
)

ISO_NAME="$(pwd)/borne-multiservices-v1.0.iso"

# Paramètres de boot communs (réutilisés dans syslinux + GRUB)
BOOT_PARAMS="boot=live components quiet splash hostname=borne-multiservices username=kiosk locales=fr_FR.UTF-8 keyboard-layouts=fr noeject nopersistent"

# ── Couleurs ──────────────────────────────────────────────────────────────────
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; RESET="\e[0m"
ok()   { echo -e "${GREEN}✅  $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠   $*${RESET}"; }
err()  { echo -e "${RED}❌  $*${RESET}"; exit 1; }
step() { echo -e "\n${YELLOW}▶▶  $*${RESET}"; }

# ── Vérification des pré-requis ───────────────────────────────────────────────
step "Vérification des pré-requis..."
for cmd in lb wget curl python3 unzip rsync xorriso git; do
    command -v "$cmd" &>/dev/null \
        || err "Commande manquante : $cmd  →  apt install live-build wget curl python3 unzip git"
done

[[ -f "$SCRIPT_DIR/menu_selector/main.py" ]] \
    || err "menu_selector/main.py introuvable à côté de ce script (${SCRIPT_DIR})"
ok "Pré-requis OK"

# ── Récapitulatif des sous-dossiers de code retenus ──────────────────────────
step "Sous-dossier de code retenu par application :"
for _app in shadowclone e-broyeur virtupack bastion-antiviral; do
    printf "    %-20s -> %s\n" "$_app" "${REPO_CODE_SUBDIR[$_app]}"
done

# ── Récupération / mise à jour des 4 dépôts sources ───────────────────────────
step "Récupération des 4 dépôts applicatifs..."
mkdir -p "$REPOS_DIR"
for app in "${!REPO_URL[@]}"; do
    dest="$REPOS_DIR/$app"
    if [[ -d "$dest/.git" ]]; then
        echo "  ↻ $app déjà cloné — git pull"
        git -C "$dest" pull --ff-only -q || warn "$app : pull échoué, on garde la copie locale"
    else
        echo "  ⬇ Clonage de $app…"
        git clone --depth 1 "${REPO_URL[$app]}" "$dest" -q
    fi
    code_subdir="${REPO_CODE_SUBDIR[$app]}"
    [[ -d "$dest/$code_subdir" ]] \
        || err "$app : sous-dossier '$code_subdir' introuvable dans $dest"
    [[ -f "$dest/$code_subdir/main.py" ]] \
        || err "$app : main.py introuvable dans $dest/$code_subdir"
done
ok "Les 4 dépôts sont prêts (${REPOS_DIR})"

# ── Installation des outils de build ─────────────────────────────────────────
step "Installation des dépendances de build..."
apt-get update -qq
apt-get install -y live-build xorriso syslinux isolinux syslinux-utils wget curl python3 unzip rsync git
ok "Outils de build installés"

# ── Préparation du répertoire de travail ──────────────────────────────────────
step "Préparation du répertoire de travail..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
lb clean 2>/dev/null || true

# ── Configuration live-build ──────────────────────────────────────────────────
step "Configuration de live-build (Debian Trixie / OpenBox / AZERTY)..."
lb config \
    --distribution trixie \
    --architectures amd64 \
    --linux-packages linux-image \
    --debian-installer none \
    --bootappend-live "${BOOT_PARAMS}" \
    --bootloaders "syslinux,grub-efi" \
    --binary-images iso-hybrid \
    --apt-options "--yes --no-install-recommends"
ok "live-build configuré"

# ── Dépôts Debian ─────────────────────────────────────────────────────────────
mkdir -p config/archives
cat > config/archives/debian.list.chroot << 'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
ok "Dépôts Debian configurés (Avast est géré par le hook 0250, pas ici)"

# ── Liste des paquets (union des besoins des 4 applications) ────────────────
step "Définition des paquets (union shadowClone + e-Broyeur + VirtuPack + Bastion-Antiviral)..."
mkdir -p config/package-lists
cat > config/package-lists/custom.list.chroot << 'EOF'
# ── Système de base (commun aux 4 projets) ───────────────────────────────────
coreutils
diffutils
sudo
live-boot
live-config
live-tools
console-setup
keyboard-configuration
locales
systemd
udev
pciutils
usbutils
acpi
network-manager
wget
curl
ca-certificates
rsync
unzip
squashfs-tools
whiptail
evince
# ── Desktop OpenBox minimal + XFCE de secours ─────────────────────────────────
xorg
xserver-xorg-video-all
xserver-xorg-video-intel
xserver-xorg-video-ati
xserver-xorg-video-nouveau
xserver-xorg-video-vesa
xserver-xorg-video-fbdev
xserver-xorg-input-all
openbox
lightdm
xfwm4
xfce4-session
xfdesktop4
xfce4-panel
xfce4-terminal
thunar
xfce4-appfinder
xfce4-power-manager
xterm
# ── Kiosk – verrouillage de session ──────────────────────────────────────────
xdotool
xbindkeys
unclutter
# ── Python + GUI (commun aux 4 projets) ──────────────────────────────────────
python3
python3-tk
python3-pip
python3-pil
python3-pil.imagetk
python3-fitz
# ── Outils disque/USB (e-Broyeur, shadowClone, VirtuPack, installateur) ─────
parted
e2fsprogs
ntfs-3g
dosfstools
exfatprogs
cryptsetup
util-linux
gparted
# ── GRUB + boot (pour compatibilité BIOS/UEFI générale) ─────────────────────
grub-common
grub-pc-bin
grub-efi-amd64-bin
grub-pc
os-prober
firmware-linux-free
firmware-linux-nonfree
# ── Virtualisation (VirtuPack) ───────────────────────────────────────────────
qemu-utils
qemu-system-x86
virt-manager
bridge-utils
libvirt-daemon
libvirt-clients
osinfo-db
osinfo-db-tools
# ── Antivirus (Bastion-Antiviral) ────────────────────────────────────────────
yara
python3-yara
clamav
clamav-daemon
clamav-freshclam
# avast ← ajouté dynamiquement par le hook 0250 (dépôt tiers, non listé ici)
EOF
ok "Liste de paquets définie"

# =============================================================================
# Hooks chroot
# =============================================================================
mkdir -p config/hooks/normal

# ── Hook 0100 : téléchargement base ClamAV (Bastion-Antiviral) ──────────────
step "Création du hook ClamAV..."
cat > config/hooks/normal/0100-clamav-db.hook.chroot << 'HOOK'
#!/bin/bash
set -euo pipefail
echo ">>> [Hook ClamAV] Mise à jour de la base virale via freshclam..."

DB_DIR="/var/lib/clamav"
LOG="/var/log/clamav-build.log"
mkdir -p "$DB_DIR"
chown clamav:clamav "$DB_DIR" 2>/dev/null || true

systemctl stop clamav-freshclam 2>/dev/null || true
systemctl stop clamav-daemon    2>/dev/null || true
systemctl disable clamav-freshclam 2>/dev/null || true

EXISTING=$(find "$DB_DIR" -name "*.cvd" -o -name "*.cld" 2>/dev/null | wc -l)
if [[ "$EXISTING" -ge 2 ]]; then
    VALID=0
    for f in "$DB_DIR"/main.cvd "$DB_DIR"/daily.cvd "$DB_DIR"/main.cld "$DB_DIR"/daily.cld; do
        if [[ -f "$f" ]] && [[ $(stat -c%s "$f" 2>/dev/null || echo 0) -gt 1048576 ]]; then
            VALID=$((VALID + 1))
        fi
    done
    if [[ "$VALID" -ge 2 ]]; then
        echo ">>> [Hook ClamAV] $EXISTING fichier(s) de base déjà présents et valides." | tee -a "$LOG"
        echo "    Tentative de mise à jour incrémentale via freshclam..." | tee -a "$LOG"
    fi
fi

FRESHCLAM_CONF="$(mktemp /tmp/freshclam-hook.XXXXXX.conf)"
cat > "$FRESHCLAM_CONF" << CONF
DatabaseDirectory $DB_DIR
UpdateLogFile $LOG
LogVerbose yes
LogTime yes
MaxAttempts 3
DatabaseMirror database.clamav.net
DatabaseMirror db.local.clamav.net
ConnectTimeout 30
ReceiveTimeout 60
Bytecode yes
CONF

echo ">>> [Hook ClamAV] Lancement de freshclam..." | tee -a "$LOG"
if freshclam --config-file="$FRESHCLAM_CONF" --stdout 2>&1 | tee -a "$LOG"; then
    COUNT=$(find "$DB_DIR" \( -name "*.cvd" -o -name "*.cld" \) | wc -l)
    echo ">>> [Hook ClamAV] ✅ Base mise à jour ($COUNT fichier(s))." | tee -a "$LOG"
else
    RC=$?
    if [[ $RC -eq 1 ]]; then
        COUNT=$(find "$DB_DIR" \( -name "*.cvd" -o -name "*.cld" \) | wc -l)
        echo ">>> [Hook ClamAV] ✅ Base déjà à jour ($COUNT fichier(s))." | tee -a "$LOG"
    else
        echo ">>> [Hook ClamAV] ⚠ freshclam code $RC — base incluse dans l'image utilisée." | tee -a "$LOG"
    fi
fi

rm -f "$FRESHCLAM_CONF"
chown clamav:clamav "$DB_DIR"/ 2>/dev/null || true
find "$DB_DIR" -name "*.cvd" -o -name "*.cld" 2>/dev/null | xargs chown clamav:clamav 2>/dev/null || true
find "$DB_DIR" -name "*.cvd" -o -name "*.cld" 2>/dev/null | xargs chmod 644 2>/dev/null || true

FINAL=$(find "$DB_DIR" -name "*.cvd" -o -name "*.cld" | wc -l)
echo ">>> [Hook ClamAV] Terminé. $FINAL fichier(s) dans $DB_DIR." | tee -a "$LOG"
HOOK
chmod +x config/hooks/normal/0100-clamav-db.hook.chroot
ok "Hook ClamAV créé"

# ── Hook 0150 : signatures tierces ClamAV (Bastion-Antiviral) ───────────────
step "Création du hook signatures tierces ClamAV..."
cat > config/hooks/normal/0150-clamav-thirdparty.hook.chroot << 'HOOK'
#!/bin/bash
set -uo pipefail

DB_DIR="/var/lib/clamav"
LOG="/var/log/clamav-thirdparty.log"
mkdir -p "$DB_DIR"

TP_OK=0
TP_SKIP=0

echo ">>> [Hook TP] Début des signatures tierces ClamAV…" | tee "$LOG"

if ! command -v clamscan &>/dev/null; then
    echo ">>> [Hook TP] clamscan introuvable — validation impossible, skip." | tee -a "$LOG"
    exit 0
fi

_is_valid_content() {
    local FILE="$1"
    local HEADER
    HEADER=$(head -c 64 "$FILE" 2>/dev/null)
    case "$HEADER" in
        '<'*|'HTTP/'*|'{"'*|'<!DOCTYPE'*|'<!doctype'*) return 1 ;;
    esac
    [[ -n "$HEADER" ]] || return 1
    return 0
}

_db_ok() {
    local OUT
    OUT=$(timeout 60 clamscan --no-summary --database="$DB_DIR" /dev/null 2>&1)
    local RC=$?
    if [[ $RC -eq 2 ]]; then
        if echo "$OUT" | grep -qiE "error loading|can't load|invalid|corrupt|can't open"; then
            return 1
        fi
    fi
    return 0
}

install_and_validate() {
    local URL="$1" FNAME="$2" MIN_SIZE="${3:-64}"
    local DEST="$DB_DIR/$FNAME"
    local TMP
    TMP="$(mktemp /tmp/clamtp_XXXXXX)"

    echo "  ⬇  $FNAME …" | tee -a "$LOG"

    if ! wget -q --timeout=30 --tries=3 -O "$TMP" "$URL" 2>>"$LOG"; then
        echo "  ⚠ $FNAME : échec réseau — ignoré" | tee -a "$LOG"
        rm -f "$TMP"; return 1
    fi

    local SIZE
    SIZE=$(stat -c%s "$TMP" 2>/dev/null || echo 0)

    if [[ "$SIZE" -lt "$MIN_SIZE" ]]; then
        echo "  ⚠ $FNAME : fichier trop petit (${SIZE} < ${MIN_SIZE} o) — ignoré" | tee -a "$LOG"
        rm -f "$TMP"; return 1
    fi

    if ! _is_valid_content "$TMP"; then
        echo "  ⚠ $FNAME : contenu invalide (HTML/erreur serveur) — ignoré" | tee -a "$LOG"
        rm -f "$TMP"; return 1
    fi

    mv "$TMP" "$DEST"
    chmod 644 "$DEST"
    chown clamav:clamav "$DEST" 2>/dev/null || true

    if _db_ok; then
        echo "  ✅ $FNAME installé et validé (${SIZE} o)" | tee -a "$LOG"
        TP_OK=$((TP_OK + 1))
        return 0
    else
        echo "  ⚠ $FNAME incompatible avec la base (conflit de format) — supprimé" | tee -a "$LOG"
        rm -f "$DEST"
        TP_SKIP=$((TP_SKIP + 1))
        return 1
    fi
}

echo ">>> [Hook TP] Sanesecurity…" | tee -a "$LOG"

SANE_FILES=(
    sanesecurity.ftm  sigwhitelist.ign2
    junk.ndb    jurlbl.ndb   jurlbla.ndb  lott.ndb
    phish.ndb   rogue.hdb    scam.ndb     blurl.ndb
    spamimg.hdb spamattach.hdb spam.ldb   shelter.ldb
    spear.ndb   spearl.ndb   badmacro.ndb
    malwarehash.hsb   hackingteam.hsb
    foxhole_generic.cdb  foxhole_filename.cdb  foxhole_js.cdb
    foxhole_js.ndb       foxhole_all.cdb        foxhole_all.ndb
    foxhole_mail.cdb     foxhole_links.ldb
    MiscreantPunch099-Low.ldb  MiscreantPunch099-INFO-Low.ldb
    porcupine.ndb  phishtank.ndb  porcupine.hsb
    bofhland_cracked_URL.ndb   bofhland_malware_URL.ndb
    bofhland_phishing_URL.ndb  bofhland_malware_attach.hdb
    winnow_malware.hdb           winnow_malware_links.ndb
    winnow_spam_complete.ndb     winnow_phish_complete_url.ndb
    winnow.complex.patterns.ldb  winnow_extended_malware.hdb
    winnow_extended_malware_links.ndb  winnow.attachments.hdb
    doppelstern.ndb   doppelstern.hdb   doppelstern-phishtank.ndb
    crdfam.clamav.hdb scamnailer.ndb
    malware.expert.ndb  malware.expert.hdb  malware.expert.ldb
    malware.expert.fp
)

SANE_BASE_URL=""

if command -v rsync &>/dev/null; then
    echo "  rsync://rsync.sanesecurity.net/sanesecurity …" | tee -a "$LOG"
    RSYNC_TMP="$(mktemp -d /tmp/sanesec_rsync_XXXXXX)"
    if rsync --timeout=30 --contimeout=15 --no-recursive -q \
        rsync://rsync.sanesecurity.net/sanesecurity/ "$RSYNC_TMP/" 2>>"$LOG" \
       && [[ $(ls "$RSYNC_TMP" 2>/dev/null | wc -l) -gt 0 ]]; then
        echo "  rsync OK — validation individuelle de chaque fichier…" | tee -a "$LOG"
        for fname in "${SANE_FILES[@]}"; do
            if [[ -f "$RSYNC_TMP/$fname" ]]; then
                SZ=$(stat -c%s "$RSYNC_TMP/$fname" 2>/dev/null || echo 0)
                if [[ "$SZ" -ge 64 ]] && _is_valid_content "$RSYNC_TMP/$fname"; then
                    DEST="$DB_DIR/$fname"
                    cp "$RSYNC_TMP/$fname" "$DEST"
                    chmod 644 "$DEST"; chown clamav:clamav "$DEST" 2>/dev/null || true
                    if _db_ok; then
                        echo "  ✅ $fname (rsync, ${SZ}o)" | tee -a "$LOG"
                        TP_OK=$((TP_OK + 1))
                    else
                        echo "  ⚠ $fname incompatible — supprimé" | tee -a "$LOG"
                        rm -f "$DEST"
                        TP_SKIP=$((TP_SKIP + 1))
                    fi
                fi
            fi
        done
        SANE_BASE_URL="rsync"
    else
        echo "  ⚠ rsync Sanesecurity inaccessible — fallback HTTP" | tee -a "$LOG"
    fi
    rm -rf "$RSYNC_TMP"
fi

if [[ -z "$SANE_BASE_URL" ]]; then
    echo "  Fallback HTTP Sanesecurity…" | tee -a "$LOG"
    for SANE_HTTP in \
        "https://mirror.ihost.md/clamav/sanesecurity" \
        "https://ftp.swin.edu.au/sanesecurity"; do
        if wget --timeout=15 --tries=1 -q --spider "$SANE_HTTP/sanesecurity.ftm" 2>/dev/null; then
            SANE_BASE_URL="$SANE_HTTP"
            echo "  Miroir joignable : $SANE_HTTP" | tee -a "$LOG"
            for fname in "${SANE_FILES[@]}"; do
                install_and_validate "$SANE_HTTP/$fname" "$fname" 64 || true
            done
            break
        fi
    done
fi

[[ -n "$SANE_BASE_URL" ]] || echo "  ⚠ Sanesecurity inaccessible — ignoré." | tee -a "$LOG"

echo ">>> [Hook TP] InterServer…" | tee -a "$LOG"
install_and_validate "http://sigs.interserver.net/interserver256.hdb" "interserver256.hdb" 500 || true
install_and_validate "http://sigs.interserver.net/topline.db"          "topline.db"          500 || true

echo ">>> [Hook TP] URLhaus…" | tee -a "$LOG"
URLHAUS_OK=false
for _url in \
    "https://urlhaus.abuse.ch/downloads/urlhaus.ndb" \
    "https://curbengh.github.io/malware-filter/urlhaus-filter-clam.ndb"; do
    if install_and_validate "$_url" "urlhaus-filter.ndb" 1000; then
        URLHAUS_OK=true; break
    fi
done
$URLHAUS_OK || echo "  ⚠ URLhaus inaccessible — ignoré." | tee -a "$LOG"

TP_FINAL=$(find "$DB_DIR" \( \
    -name "*.ndb" -o -name "*.hdb" -o -name "*.hsb" \
    -o -name "*.db"  -o -name "*.ftm" -o -name "*.ldb" \
    -o -name "*.cdb" -o -name "*.fp"  -o -name "*.ign2" \
    \) 2>/dev/null | wc -l)

echo ">>> [Hook TP] ✅ Terminé : $TP_OK installés, $TP_SKIP rejetés, $TP_FINAL fichier(s) tiers actifs." | tee -a "$LOG"

if ! _db_ok; then
    echo ">>> [Hook TP] ❌ La base ne se charge toujours pas — purge totale des fichiers tiers." | tee -a "$LOG"
    find "$DB_DIR" \( -name "*.ndb" -o -name "*.hdb" -o -name "*.hsb" \
        -o -name "*.db" -o -name "*.ftm" -o -name "*.ldb" \
        -o -name "*.cdb" -o -name "*.fp" -o -name "*.ign2" \) \
        -delete 2>/dev/null || true
    echo ">>> [Hook TP] Purge effectuée. ClamAV fonctionnera avec les bases officielles seules." | tee -a "$LOG"
fi
HOOK
chmod +x config/hooks/normal/0150-clamav-thirdparty.hook.chroot
ok "Hook signatures tierces ClamAV créé"

# ── Hook 0200 : règles YARA signature-base (Bastion-Antiviral) ──────────────
step "Création du hook YARA..."
cat > config/hooks/normal/0200-yara-rules.hook.chroot << HOOK
#!/bin/bash
set -euo pipefail
echo ">>> [Hook YARA] Téléchargement de signature-base (Florian Roth)..."

YARA_DIR="/var/lib/yara-rules/signature-base"
TMP_ZIP="/tmp/signature-base.zip"
LOG="/var/log/yara-build.log"
URL="${SIGBASE_URL}"

mkdir -p "\$YARA_DIR"

EXISTING=\$(find "\$YARA_DIR" -name "*.yar" 2>/dev/null | wc -l)
if [[ "\$EXISTING" -gt 50 ]]; then
    echo ">>> [Hook YARA] \$EXISTING règles déjà présentes — skip téléchargement." | tee -a "\$LOG"
    exit 0
fi

wget -q --show-progress -O "\$TMP_ZIP" "\$URL" 2>>"\$LOG" || {
    echo "  ⚠ Impossible de télécharger signature-base." | tee -a "\$LOG"
    echo "    Les règles YARA incluses dans l'image seront utilisées." | tee -a "\$LOG"
    exit 0
}

python3 - "\$TMP_ZIP" "\$YARA_DIR" << 'PYEOF'
import sys, zipfile, os

zip_path = sys.argv[1]
out_dir  = sys.argv[2]
PREFIX   = "signature-base-master/yara/"
count    = 0
os.makedirs(out_dir, exist_ok=True)

with zipfile.ZipFile(zip_path) as zf:
    for member in zf.namelist():
        if (member.startswith(PREFIX)
                and member.endswith((".yar", ".yara"))
                and not member.endswith("/")):
            fname  = os.path.basename(member)
            target = os.path.join(out_dir, fname)
            with zf.open(member) as src, open(target, "wb") as dst:
                dst.write(src.read())
            count += 1

print(f"  {count} fichier(s) de règles YARA extraits.")
PYEOF

rm -f "\$TMP_ZIP"
COUNT=\$(find "\$YARA_DIR" -name "*.yar" | wc -l)
echo ">>> [Hook YARA] \$COUNT règle(s) installée(s)." | tee -a "\$LOG"
HOOK
chmod +x config/hooks/normal/0200-yara-rules.hook.chroot
ok "Hook YARA créé"

# ── Hook 0250 : installation Avast Business for Linux (Bastion-Antiviral) ───
step "Création du hook d'installation Avast Business..."
cat > config/hooks/normal/0250-avast-install.hook.chroot << 'HOOK'
#!/bin/bash
set -uo pipefail
LOG="/var/log/avast-install.log"
echo ">>> [Hook Avast] Début (procédure officielle)…" | tee "$LOG"

if command -v avast &>/dev/null || command -v scan &>/dev/null; then
    echo ">>> [Hook Avast] Avast déjà présent — skip." | tee -a "$LOG"
    exit 0
fi

apt-get install -y --no-install-recommends ca-certificates curl apt-transport-https >>"$LOG" 2>&1 \
    || { echo ">>> [Hook Avast] ⚠ Pré-requis manquants." | tee -a "$LOG"; exit 0; }

DIST=$(. /etc/os-release; echo "${ID}-${VERSION_CODENAME}")
echo ">>> [Hook Avast] Distribution détectée : $DIST" | tee -a "$LOG"

case "$DIST" in
    debian-buster|debian-bullseye|debian-bookworm|ubuntu-bionic|ubuntu-focal|ubuntu-jammy|ubuntu-noble)
        echo ">>> [Hook Avast] Distribution supportée." | tee -a "$LOG" ;;
    *)
        echo ">>> [Hook Avast] ⚠ Distribution '$DIST' non reconnue — essai avec debian-bookworm." | tee -a "$LOG"
        DIST="debian-bookworm" ;;
esac

ASC_DEST="/etc/apt/trusted.gpg.d/avast.asc"
LIST="/etc/apt/sources.list.d/avast.list"
GPG_URL="https://repo.avcdn.net/linux-av/doc/avast-gpg-key.asc"

if [[ ! -s "$ASC_DEST" ]]; then
    echo ">>> [Hook Avast] Installation de la clé → $ASC_DEST" | tee -a "$LOG"
    if curl -fsSL --max-time 30 --retry 3 "$GPG_URL" | tee "$ASC_DEST" >>"$LOG" 2>&1 \
       && grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$ASC_DEST" 2>/dev/null; then
        chmod 644 "$ASC_DEST"
        echo ">>> [Hook Avast] ✅ Clé ASCII armored installée." | tee -a "$LOG"
    else
        echo ">>> [Hook Avast] ⚠ Impossible d'obtenir la clé GPG (réseau ?)." | tee -a "$LOG"
        echo "    Avast ne sera PAS installé dans cette image (non bloquant)." | tee -a "$LOG"
        rm -f "$ASC_DEST"
        exit 0
    fi
else
    echo ">>> [Hook Avast] Clé déjà présente : $ASC_DEST" | tee -a "$LOG"
fi

if [[ ! -f "$LIST" ]]; then
    echo "deb [signed-by=$ASC_DEST] https://repo.avcdn.net/linux-av/deb $DIST release" > "$LIST"
    echo ">>> [Hook Avast] Dépôt ajouté : $LIST" | tee -a "$LOG"
    cat "$LIST" | tee -a "$LOG"
else
    echo ">>> [Hook Avast] Dépôt déjà configuré : $LIST" | tee -a "$LOG"
fi

echo ">>> [Hook Avast] apt-get update…" | tee -a "$LOG"
apt-get update -qq >>"$LOG" 2>&1 || {
    echo ">>> [Hook Avast] ⚠ apt-get update a échoué — vérifiez la connexion." | tee -a "$LOG"
}

echo ">>> [Hook Avast] Installation : avast avast-fss avast-rest avast-license…" | tee -a "$LOG"
AVAST_INSTALLED=false
if apt-get install -y --no-install-recommends avast avast-fss avast-rest avast-license >>"$LOG" 2>&1; then
    echo ">>> [Hook Avast] ✅ Paquets Avast installés." | tee -a "$LOG"
    AVAST_INSTALLED=true
elif apt-get install -y --no-install-recommends avast avast-license >>"$LOG" 2>&1; then
    echo ">>> [Hook Avast] ✅ avast + avast-license installés (avast-fss/rest optionnels)." | tee -a "$LOG"
    AVAST_INSTALLED=true
else
    echo ">>> [Hook Avast] ⚠ Échec d'installation du paquet avast." | tee -a "$LOG"
    echo "    L'image sera fonctionnelle sans Avast (ClamAV + YARA opérationnels)." | tee -a "$LOG"
    exit 0
fi

if $AVAST_INSTALLED; then
    for BIN in avast scan avastlic; do
        PATH_BIN=$(command -v "$BIN" 2>/dev/null || true)
        [[ -n "$PATH_BIN" ]] && echo ">>> [Hook Avast] Binaire : $PATH_BIN" | tee -a "$LOG"
    done
    systemctl disable avast.target >>"$LOG" 2>&1 || true
    systemctl disable avast        >>"$LOG" 2>&1 || true
    echo ">>> [Hook Avast] Service avast désactivé au boot." | tee -a "$LOG"
fi

mkdir -p /etc/avast
chmod 755 /etc/avast

cat > /etc/avast/README_LICENCE.txt << 'INFO'
Avast Business Antivirus for Linux est installé mais PAS activé.
Une licence Business est requise pour utiliser le moteur de scan.
Activez-la depuis le panneau Admin de l'application Antivirus USB
(code d'activation, fichier .avastlic sur clé USB, ou parcourir le
système de fichiers). Voir https://www.avast.com/business/linux
INFO
chmod 644 /etc/avast/README_LICENCE.txt

echo ">>> [Hook Avast] ✅ Installation terminée. Licence requise — voir /etc/avast/README_LICENCE.txt" | tee -a "$LOG"
HOOK
chmod +x config/hooks/normal/0250-avast-install.hook.chroot
ok "Hook Avast créé"

# ── Hook 0300 : configuration système, utilisateur kiosque, session ─────────
step "Création du hook de configuration système / menu kiosque..."
cat > config/hooks/normal/0300-system-config.hook.chroot << 'HOOK'
#!/bin/bash
set -euo pipefail
echo ">>> [Hook Système] Configuration locale, utilisateur, kiosque menu..."

# Locale française
echo "fr_FR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen fr_FR.UTF-8
update-locale LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8

# ── Utilisateur kiosque (autologin, sudo sans mot de passe) ─────────────────
# NOPASSWD est nécessaire : les 4 applications exigent root (os.geteuid()==0)
# et sont lancées via `sudo -E python3 ...` par leurs wrappers respectifs.
if ! id kiosk &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,plugdev,cdrom,dialout,libvirt,kvm kiosk
    echo "kiosk:kiosk" | chpasswd
fi
echo "kiosk ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/kiosk
chmod 0440 /etc/sudoers.d/kiosk

# ── Répertoires applicatifs ──────────────────────────────────────────────────
for app in shadowclone e-broyeur virtupack bastion-antiviral; do
    mkdir -p "/opt/apps/$app"
done
mkdir -p /opt/kiosk-menu
mkdir -p /etc/kiosk-menu
mkdir -p /var/log/kiosk-menu
chown kiosk:kiosk /var/log/kiosk-menu
mkdir -p /mnt/avscan_usb && chmod 777 /mnt/avscan_usb
mkdir -p /etc/virusscanner && chmod 700 /etc/virusscanner
mkdir -p /var/lib/yara-rules/signature-base /var/lib/yara-rules/custom
chmod -R 755 /var/lib/yara-rules
mkdir -p /opt/pdf && chmod 775 /opt/pdf && chown kiosk:kiosk /opt/pdf 2>/dev/null || true
mkdir -p /opt/img && chmod 755 /opt/img

# ── Mot de passe admin du menu (panneau Administration) ─────────────────────
# Valeur par défaut à CHANGER IMPÉRATIVEMENT après le premier déploiement.
# Le menu tourne en tant qu'utilisateur "kiosk" (pas root) : ce fichier doit
# donc lui appartenir pour qu'il puisse le lire au moment de vérifier le
# mot de passe saisi.
if [[ ! -f /etc/kiosk-menu/admin.pass ]]; then
    echo "0000" > /etc/kiosk-menu/admin.pass
fi
chown kiosk:kiosk /etc/kiosk-menu/admin.pass
chmod 600 /etc/kiosk-menu/admin.pass

# ── État des boutons du menu principal (activé/désactivé par appli) ────────
# Écrit/lu par le menu lui-même (utilisateur kiosk) depuis le panneau
# d'Administration : doit donc lui appartenir également.
if [[ ! -f /etc/kiosk-menu/apps_state.json ]]; then
    cat > /etc/kiosk-menu/apps_state.json << 'JSON'
{
  "shadowclone": true,
  "e-broyeur": true,
  "virtupack": true,
  "bastion-antiviral": true
}
JSON
fi
chown kiosk:kiosk /etc/kiosk-menu/apps_state.json
chmod 644 /etc/kiosk-menu/apps_state.json
chown kiosk:kiosk /etc/kiosk-menu

# ── Wrappers de lancement (un par application, tous root via sudo) ─────────
cat > /usr/local/bin/app-shadowclone << 'WRAPPER'
#!/bin/bash
exec sudo -E python3 /opt/apps/shadowclone/main.py "$@"
WRAPPER

cat > /usr/local/bin/app-broyeur << 'WRAPPER'
#!/bin/bash
exec sudo -E python3 /opt/apps/e-broyeur/main.py "$@"
WRAPPER

cat > /usr/local/bin/app-virtupack << 'WRAPPER'
#!/bin/bash
exec sudo -E python3 /opt/apps/virtupack/main.py "$@"
WRAPPER

cat > /usr/local/bin/app-antivirus << 'WRAPPER'
#!/bin/bash
exec sudo -E python3 /opt/apps/bastion-antiviral/main.py "$@"
WRAPPER

chmod 755 /usr/local/bin/app-shadowclone /usr/local/bin/app-broyeur \
          /usr/local/bin/app-virtupack /usr/local/bin/app-antivirus

# ── Wrapper du menu de sélection ─────────────────────────────────────────────
cat > /usr/local/bin/kiosk-menu << 'WRAPPER'
#!/bin/bash
exec python3 /opt/kiosk-menu/main.py "$@"
WRAPPER
chmod 755 /usr/local/bin/kiosk-menu

# ── OPENBOX : configuration globale kiosque ──────────────────────────────────
mkdir -p /etc/xdg/openbox
cat > /etc/xdg/openbox/rc.xml << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc"
                xmlns:xi="http://www.w3.org/2001/XInclude">
  <applications>
    <application class="*">
      <fullscreen>yes</fullscreen>
      <decor>no</decor>
      <maximized>yes</maximized>
      <layer>above</layer>
      <focus>yes</focus>
    </application>
  </applications>
  <keyboard>
  </keyboard>
  <mouse>
    <context name="Root">
    </context>
  </mouse>
  <desktops>
    <number>1</number>
  </desktops>
</openbox_config>
XML

cat > /etc/xdg/openbox/autostart << 'AUTOSTART'
# Aucun programme de bureau — kiosque minimal
AUTOSTART

# ── Désactiver Ctrl+Alt+Backspace (ZAP) et VT switching + anti-veille ───────
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/99-kiosk-lock.conf << 'XORGCONF'
Section "ServerFlags"
    Option "DontZap"       "true"
    Option "DontVTSwitch"  "true"
    Option "BlankTime"     "0"
    Option "StandbyTime"   "0"
    Option "SuspendTime"   "0"
    Option "OffTime"       "0"
EndSection
Section "Monitor"
    Identifier "Monitor0"
    Option "DPMS" "false"
EndSection
XORGCONF

mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/no-suspend.conf << 'EOF'
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF

# ── Session kiosque : dispatcher live / installateur ─────────────────────────
# Appelée par LightDM via kiosk-menu.desktop. Lit /proc/cmdline : si
# "installer=1" → lance l'installateur sur disque ; sinon → menu de
# sélection en boucle (relance uniquement en cas de crash).
cat > /usr/local/bin/kiosk-menu-session.sh << 'SESSION'
#!/bin/bash
export DISPLAY=:0
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

xset s off -dpms 2>/dev/null || true
xset s noblank   2>/dev/null || true

openbox &
OB_PID=$!
sleep 1

xsetroot -solid black 2>/dev/null || true

if grep -q "installer=1" /proc/cmdline 2>/dev/null; then
    # ── Mode installateur ────────────────────────────────────────────────────
    xterm -title "Borne Multiservices - Installation" \
          -fa "Monospace" -fs 12 \
          -bg "#0d0d1a" -fg "#e0e0e0" \
          -e "sudo /usr/local/bin/install-to-disk.sh"
else
    # ── Mode live kiosque ────────────────────────────────────────────────────
    while true; do
        /usr/local/bin/kiosk-menu
        [[ $? -eq 0 ]] && break
        sleep 1
    done

    kill "$OB_PID" 2>/dev/null || true
    exec xfce4-session
fi

kill "$OB_PID" 2>/dev/null || true
SESSION
chmod 755 /usr/local/bin/kiosk-menu-session.sh

# ── Session pour le système INSTALLÉ (xfwm4, plus robuste en pérenne) ──────
cat > /usr/local/bin/kiosk-menu-session-installed.sh << 'SESSION'
#!/bin/bash
export DISPLAY=:0
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

xset s off -dpms 2>/dev/null || true
xset s noblank   2>/dev/null || true

xsetroot -solid black 2>/dev/null || true

xfwm4 --compositor=off &
WM_PID=$!
sleep 1

while true; do
    /usr/local/bin/kiosk-menu
    [[ $? -eq 0 ]] && break
    sleep 1
done

kill "$WM_PID" 2>/dev/null || true
exec xfce4-session
SESSION
chmod 755 /usr/local/bin/kiosk-menu-session-installed.sh

# ── Fichiers .desktop pour LightDM (xsessions) ───────────────────────────────
mkdir -p /usr/share/xsessions
cat > /usr/share/xsessions/kiosk-menu.desktop << 'XSESSION'
[Desktop Entry]
Name=Borne Multiservices
Comment=Menu de sélection (cloneur, broyeur, P2V, antivirus)
Exec=/usr/local/bin/kiosk-menu-session.sh
TryExec=/usr/local/bin/kiosk-menu-session.sh
Type=Application
XSESSION

cat > /usr/share/xsessions/kiosk-menu-installed.desktop << 'XSESSION'
[Desktop Entry]
Name=Borne Multiservices (installée)
Comment=Menu de sélection, système installé sur disque (xfwm4)
Exec=/usr/local/bin/kiosk-menu-session-installed.sh
TryExec=/usr/local/bin/kiosk-menu-session-installed.sh
Type=Application
XSESSION

# ── LightDM autologin ────────────────────────────────────────────────────────
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf << 'LDM'
[Seat:*]
autologin-user=kiosk
autologin-session=kiosk-menu
autologin-user-timeout=0
allow-guest=false
LDM

mkdir -p /etc/skel
cat > /etc/skel/.dmrc << 'DMRC'
[Desktop]
Session=kiosk-menu
DMRC

# ── Script install-to-disk.sh (rsync du système live complet, UEFI/BIOS) ────
# Générique : installe TOUT le système live (4 applications + menu +
# ClamAV/YARA/Avast + libvirt) sur le disque cible, quel que soit le
# service que l'utilisateur comptait lancer. Adapté du mécanisme déjà
# éprouvé de Bastion-Antiviral.
cat > /usr/local/bin/install-to-disk.sh << 'INSTALLER'
#!/bin/bash
set -e

TITLE="Borne Multiservices - Installation"
TARGET_MNT="/mnt/kiosk-target"

part() {
    case "$1" in
        *nvme*|*mmcblk*) echo "${1}p${2}" ;;
        *)               echo "${1}${2}"  ;;
    esac
}

# Détection des disques disponibles (exclure loop et le média live)
LIVE_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's|/dev/||;s|[0-9]*$||' || true)
DISKS=$(lsblk -d -o NAME,SIZE,MODEL -n | grep -v "^loop" | grep -v "^${LIVE_DEV}" || true)

if [ -z "$DISKS" ]; then
    whiptail --title "$TITLE" --msgbox "Aucun disque cible détecté." 8 55
    exit 1
fi

MENU_ARGS=()
while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    rest=$(echo "$line" | awk '{$1=""; print $0}' | xargs)
    MENU_ARGS+=("/dev/$name" "$rest")
done <<< "$DISKS"

TARGET=$(whiptail --title "$TITLE" \
    --menu "Choisir le disque cible\n⚠  TOUTES LES DONNÉES SERONT EFFACÉES" \
    20 72 10 "${MENU_ARGS[@]}" \
    3>&1 1>&2 2>&3) || { echo "Installation annulée."; exit 0; }

whiptail --title "$TITLE" --yesno \
"⚠  AVERTISSEMENT FINAL

Toutes les données sur $TARGET seront définitivement effacées.
Le système sera installé en mode kiosque (démarrage automatique
du menu de sélection des 4 applications).

Confirmer l'installation sur $TARGET ?" \
13 62 || { echo "Installation annulée."; exit 0; }

UEFI=0
[ -d /sys/firmware/efi ] && UEFI=1

# ── Partitionnement ───────────────────────────────────────────────────────────
whiptail --title "$TITLE" --infobox "Partitionnement de $TARGET..." 5 56
wipefs -a "$TARGET"

if [ "$UEFI" -eq 1 ]; then
    parted -s "$TARGET" mklabel gpt
    parted -s "$TARGET" mkpart ESP  fat32 1MiB 513MiB
    parted -s "$TARGET" set 1 esp on
    parted -s "$TARGET" mkpart root ext4 513MiB 100%
    EFI_PART="$(part "$TARGET" 1)"
    ROOT_PART="$(part "$TARGET" 2)"
else
    parted -s "$TARGET" mklabel msdos
    parted -s "$TARGET" mkpart primary ext4 1MiB 100%
    parted -s "$TARGET" set 1 boot on
    ROOT_PART="$(part "$TARGET" 1)"
fi

# ── Formatage ─────────────────────────────────────────────────────────────────
whiptail --title "$TITLE" --infobox "Formatage des partitions..." 5 50
mkfs.ext4 -F "$ROOT_PART"
[ "$UEFI" -eq 1 ] && mkfs.fat -F32 "$EFI_PART"

# ── Montage ───────────────────────────────────────────────────────────────────
whiptail --title "$TITLE" --infobox "Montage des partitions cibles..." 5 56
mkdir -p "$TARGET_MNT"
mount "$ROOT_PART" "$TARGET_MNT"
[ "$UEFI" -eq 1 ] && { mkdir -p "$TARGET_MNT/boot/efi"; mount "$EFI_PART" "$TARGET_MNT/boot/efi"; }

# ── Copie rsync (tout le système live : 4 apps + menu + antivirus + libvirt) ─
whiptail --title "$TITLE" --infobox \
    "Copie du système (4 applications + menu + antivirus)...\nCette étape dure plusieurs minutes." \
    7 62
rsync -aHAX \
    --exclude=/proc   --exclude=/sys    --exclude=/dev  \
    --exclude=/run    --exclude=/mnt    --exclude=/media \
    --exclude=/tmp    --exclude=/live   \
    / "$TARGET_MNT"/

mkdir -p "$TARGET_MNT"/{proc,sys,dev,run,mnt,media,tmp}
chmod 1777 "$TARGET_MNT/tmp"

# ── fstab ─────────────────────────────────────────────────────────────────────
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
{
    echo "UUID=$ROOT_UUID  /          ext4  errors=remount-ro  0  1"
    if [ "$UEFI" -eq 1 ]; then
        EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
        echo "UUID=$EFI_UUID  /boot/efi  vfat  umask=0077         0  1"
    fi
    echo "tmpfs  /tmp  tmpfs  defaults,nosuid,nodev  0  0"
} > "$TARGET_MNT/etc/fstab"

# ── Masquer les services live (inutiles sur le système installé) ─────────────
for svc in live-boot live-config live-tools live-config-components; do
    chroot "$TARGET_MNT" systemctl mask "$svc" 2>/dev/null || true
done
rm -f "$TARGET_MNT/etc/live/boot.conf" 2>/dev/null || true

# ── LightDM : basculer sur la session "installée" (xfwm4 kiosque) ────────────
mkdir -p "$TARGET_MNT/etc/lightdm/lightdm.conf.d"
cat > "$TARGET_MNT/etc/lightdm/lightdm.conf.d/50-autologin.conf" << 'LIGHTDM_EOF'
[Seat:*]
autologin-user=kiosk
autologin-session=kiosk-menu-installed
autologin-user-timeout=0
allow-guest=false
LIGHTDM_EOF

[ -f "$TARGET_MNT/etc/skel/.dmrc" ] && \
cat > "$TARGET_MNT/etc/skel/.dmrc" << 'DMRC_EOF'
[Desktop]
Session=kiosk-menu-installed
DMRC_EOF

[ -f "$TARGET_MNT/home/kiosk/.dmrc" ] && \
cat > "$TARGET_MNT/home/kiosk/.dmrc" << 'DMRC_EOF'
[Desktop]
Session=kiosk-menu-installed
DMRC_EOF

# ── GRUB ──────────────────────────────────────────────────────────────────────
cat > "$TARGET_MNT/etc/default/grub" << 'GRUBCFG'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Borne Multiservices"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUBCFG

whiptail --title "$TITLE" --infobox "Installation du chargeur d'amorçage GRUB..." 5 58
mount --bind /dev  "$TARGET_MNT/dev"
mount --bind /proc "$TARGET_MNT/proc"
mount --bind /sys  "$TARGET_MNT/sys"
[ "$UEFI" -eq 1 ] && \
    mount --bind /sys/firmware/efi/efivars \
                 "$TARGET_MNT/sys/firmware/efi/efivars" 2>/dev/null || true

if [ "$UEFI" -eq 1 ]; then
    chroot "$TARGET_MNT" grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=BorneMultiservices \
        --recheck
else
    chroot "$TARGET_MNT" grub-install --target=i386-pc --recheck "$TARGET"
fi
chroot "$TARGET_MNT" update-grub

umount "$TARGET_MNT/sys/firmware/efi/efivars" 2>/dev/null || true
umount "$TARGET_MNT/sys"
umount "$TARGET_MNT/proc"
umount "$TARGET_MNT/dev"
[ "$UEFI" -eq 1 ] && umount "$TARGET_MNT/boot/efi"
umount "$TARGET_MNT"

whiptail --title "$TITLE" --msgbox \
"✅  Installation terminée !

Retirez le support live et redémarrez : la borne démarrera
directement sur le menu de sélection installé sur $TARGET." \
10 62
INSTALLER
chmod 755 /usr/local/bin/install-to-disk.sh

echo ">>> [Hook Système] OK ✅"
HOOK
chmod +x config/hooks/normal/0300-system-config.hook.chroot
ok "Hook système / menu kiosque créé"

# ── Hook 0310 : libvirt / qemu (spécificité VirtuPack – VM sur disque externe)
step "Création du hook libvirt / qemu (VirtuPack)..."
cat > config/hooks/normal/0310-virtupack-libvirt.hook.chroot << 'HOOK'
#!/bin/bash
set -euo pipefail
echo ">>> [Hook VirtuPack] Configuration libvirt / qemu.conf (disques amovibles)..."

mkdir -p /etc/libvirt

# qemu.conf : exécution en root + ACL étendue aux blocs amovibles courants.
# Nécessaire pour que virt-manager puisse lancer une VM dont l'image (qcow2,
# raw...) est stockée sur un disque externe monté en cours de session
# (clé USB, disque USB) plutôt que sur le disque système.
# Note : ajustez cgroup_device_acl si le disque externe apparaît au-delà
# de /dev/sdf (ex. plusieurs hubs USB en cascade).
cat > /etc/libvirt/qemu.conf << 'EOF'
# VirtuPack – accès QEMU aux supports amovibles (virt-manager)
user = "root"
group = "root"

cgroup_device_acl = [
"/dev/null", "/dev/full", "/dev/zero",
"/dev/random", "/dev/urandom",
"/dev/ptmx", "/dev/kvm",
"/dev/rtc", "/dev/hpet",
"/dev/sdb", "/dev/sdc", "/dev/sdd",
"/dev/sde", "/dev/sdf"
]
EOF

# Service one-shot : démarre libvirtd et ajoute l'utilisateur kiosque au
# groupe libvirt (déjà fait via useradd -G dans le hook 0300, ce service
# est un filet de sécurité en cas de réordonnancement des hooks).
cat > /etc/systemd/system/vp-libvirt-setup.service << 'EOF'
[Unit]
Description=VirtuPack - initialisation libvirt pour supports amovibles
After=network.target
Wants=libvirtd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/systemctl start libvirtd.service
ExecStartPost=/bin/sh -c 'for i in $(seq 1 20); do [ -S /var/run/libvirt/libvirt-sock ] && exit 0; sleep 0.5; done; exit 0'
ExecStartPost=/usr/sbin/usermod -a -G libvirt kiosk

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/libvirtd.service \
    /etc/systemd/system/multi-user.target.wants/libvirtd.service
ln -sf /etc/systemd/system/vp-libvirt-setup.service \
    /etc/systemd/system/multi-user.target.wants/vp-libvirt-setup.service

# ── IMPORTANT : aucune règle udev ne touche /sys/block/*/queue/rotational ───
# ici. e-Broyeur en dépend directement (is_ssd()) pour choisir le bon
# algorithme d'effacement (mécanique vs SSD) : la forcer casserait cette
# détection pour les vrais disques durs mécaniques branchés en USB.

echo ">>> [Hook VirtuPack] OK ✅"
HOOK
chmod +x config/hooks/normal/0310-virtupack-libvirt.hook.chroot
ok "Hook libvirt/qemu (VirtuPack) créé"

# ── Hook 0400 : permissions finales (toutes applications) ───────────────────
step "Création du hook de permissions final..."
cat > config/hooks/normal/0400-permissions.hook.chroot << 'HOOK'
#!/bin/bash
set -euo pipefail
echo ">>> [Hook Permissions] Finalisation..."

# Applications Python
for app in shadowclone e-broyeur virtupack bastion-antiviral; do
    [[ -d "/opt/apps/$app" ]] || continue
    find "/opt/apps/$app" -name "*.py" -exec chmod 644 {} \;
    chmod 755 "/opt/apps/$app"
done
chmod 644 /opt/kiosk-menu/main.py 2>/dev/null || true
chmod 755 /opt/kiosk-menu

# Fichiers d'état/administration du menu (doivent rester lisibles/inscriptibles par kiosk)
[[ -f /etc/kiosk-menu/admin.pass ]] && chown kiosk:kiosk /etc/kiosk-menu/admin.pass && chmod 600 /etc/kiosk-menu/admin.pass
[[ -f /etc/kiosk-menu/apps_state.json ]] && chown kiosk:kiosk /etc/kiosk-menu/apps_state.json && chmod 644 /etc/kiosk-menu/apps_state.json
chown kiosk:kiosk /etc/kiosk-menu 2>/dev/null || true
mkdir -p /var/log/kiosk-menu && chown kiosk:kiosk /var/log/kiosk-menu

# ClamAV – bases officielles + signatures tierces
mkdir -p /var/lib/clamav /var/log/clamav /var/run/clamav
chown -R clamav:clamav /var/lib/clamav /var/log/clamav /var/run/clamav 2>/dev/null || true
chmod 755 /var/lib/clamav /var/log/clamav /var/run/clamav
find /var/lib/clamav \( -name "*.cvd" -o -name "*.cld" \) 2>/dev/null \
    | xargs chmod 644 2>/dev/null || true
find /var/lib/clamav \( -name "*.ndb" -o -name "*.hdb" -o -name "*.hsb" \
    -o -name "*.db" -o -name "*.ftm" -o -name "*.ldb" \
    -o -name "*.cdb" -o -name "*.fp" \) 2>/dev/null \
    | xargs chown clamav:clamav 2>/dev/null || true
find /var/lib/clamav \( -name "*.ndb" -o -name "*.hdb" -o -name "*.hsb" \
    -o -name "*.db" -o -name "*.ftm" -o -name "*.ldb" \
    -o -name "*.cdb" -o -name "*.fp" \) 2>/dev/null \
    | xargs chmod 644 2>/dev/null || true

if command -v clamscan &>/dev/null; then
    _CVAL_TMP="$(mktemp /tmp/clamval_XXXXXX)"
    if ! clamscan --no-summary --database=/var/lib/clamav "$_CVAL_TMP" &>/dev/null; then
        echo ">>> [Hook Perms] ⚠ Base invalide — isolation en cours…"
        CULPRITS_P=0
        while ! clamscan --no-summary --database=/var/lib/clamav "$_CVAL_TMP" &>/dev/null; do
            QDIR="$(mktemp -d /tmp/clamav_perms_quar_XXXXXX)"
            FOUND_P=false
            for f in /var/lib/clamav/*.ndb /var/lib/clamav/*.hdb /var/lib/clamav/*.hsb \
                     /var/lib/clamav/*.db  /var/lib/clamav/*.ftm /var/lib/clamav/*.ldb \
                     /var/lib/clamav/*.cdb /var/lib/clamav/*.fp; do
                [ -f "$f" ] || continue
                BNAME=$(basename "$f")
                mv "$f" "$QDIR/"
                if clamscan --no-summary --database=/var/lib/clamav "$_CVAL_TMP" &>/dev/null; then
                    echo "    Suppression : $BNAME (coupable)"
                    rm -f "$QDIR/$BNAME"
                    CULPRITS_P=$((CULPRITS_P + 1))
                    FOUND_P=true
                    break
                else
                    mv "$QDIR/$BNAME" /var/lib/clamav/
                fi
            done
            rm -rf "$QDIR"
            if ! $FOUND_P; then
                echo ">>> [Hook Perms] ⚠ Conflit non isolable — purge des fichiers tiers."
                find /var/lib/clamav \( -name "*.ndb" -o -name "*.hdb" -o -name "*.hsb" \
                    -o -name "*.db" -o -name "*.ftm" -o -name "*.ldb" \
                    -o -name "*.cdb" -o -name "*.fp" \) -delete 2>/dev/null || true
                break
            fi
        done
        [ "$CULPRITS_P" -gt 0 ] && echo ">>> [Hook Perms] ✅ Base assainie ($CULPRITS_P fichier(s) retiré(s))."
    fi
    rm -f "$_CVAL_TMP"
fi

# YARA
chmod -R 755 /var/lib/yara-rules

# Avast (si installé)
if [ -d /etc/avast ]; then
    chmod 755 /etc/avast
    [ -f /etc/avast/license.avastlic ] && chmod 644 /etc/avast/license.avastlic || true
fi
if [ -d /var/lib/avast ]; then
    chmod -R 755 /var/lib/avast 2>/dev/null || true
fi

chown -R kiosk:kiosk /home/kiosk/ 2>/dev/null || true

echo ">>> [Hook Permissions] OK ✅"
HOOK
chmod +x config/hooks/normal/0400-permissions.hook.chroot
ok "Hook permissions créé"

# =============================================================================
# Copie du code des 4 applications + du menu de sélection
# =============================================================================
step "Copie du code des 4 applications dans le chroot..."
for app in shadowclone e-broyeur virtupack bastion-antiviral; do
    src="$REPOS_DIR/$app/${REPO_CODE_SUBDIR[$app]}"
    dest="config/includes.chroot/opt/apps/$app"
    mkdir -p "$dest"
    cp -r "$src"/*.py "$dest/" 2>/dev/null || true
    ok "  $app : copié depuis ${REPO_CODE_SUBDIR[$app]}/ ($(find "$dest" -name '*.py' | wc -l) fichier(s))"
done

step "Copie du menu de sélection..."
mkdir -p config/includes.chroot/opt/kiosk-menu
cp "$SCRIPT_DIR/menu_selector/main.py" config/includes.chroot/opt/kiosk-menu/main.py
ok "Menu copié"

# =============================================================================
# Menus de boot (syslinux BIOS + GRUB UEFI) – 3 entrées
# =============================================================================
step "Création des menus de boot (syslinux + GRUB EFI)..."
mkdir -p config/includes.binary/isolinux
cat > config/includes.binary/isolinux/isolinux.cfg << EOF
UI vesamenu.c32
DEFAULT live
TIMEOUT 150
PROMPT 0

MENU TITLE Borne Multiservices - Menu de demarrage

LABEL live
  MENU LABEL > Demarrer (menu de selection)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img ${BOOT_PARAMS}

LABEL install
  MENU LABEL > Installer sur le disque (kiosque persistant)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img ${BOOT_PARAMS} installer=1

LABEL live-safe
  MENU LABEL > Demarrer - Sans echec (nomodeset)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img ${BOOT_PARAMS} nomodeset
EOF
echo "# replaced by isolinux.cfg" > config/includes.binary/isolinux/live.cfg

mkdir -p config/includes.binary/boot/grub
cat > config/includes.binary/boot/grub/grub.cfg << GRUBMENU
set default=0
set timeout=15

if [ x\$feature_all_video_module = xy ]; then
  insmod all_video
fi

menuentry "Demarrer (menu de selection)" {
  linux /live/vmlinuz ${BOOT_PARAMS}
  initrd /live/initrd.img
}

menuentry "Installer sur le disque (kiosque persistant)" {
  linux /live/vmlinuz ${BOOT_PARAMS} installer=1
  initrd /live/initrd.img
}

menuentry "Demarrer - Sans echec (nomodeset)" {
  linux /live/vmlinuz ${BOOT_PARAMS} nomodeset
  initrd /live/initrd.img
}
GRUBMENU

mkdir -p config/includes.binary/EFI/boot
cp config/includes.binary/boot/grub/grub.cfg config/includes.binary/EFI/boot/grub.cfg
ok "Menus de boot créés"

# ── Hook 9999 (BINAIRE) : filet de sécurité après lb_binary ─────────────────
step "Création du hook de boot (filet de sécurité)..."
mkdir -p config/hooks/normal
cat << HOOK > config/hooks/normal/9999-bootmenu.hook.binary
#!/bin/bash
set -e

BOOT_PARAMS="${BOOT_PARAMS}"

write_syslinux() {
    local DIR="\$1"
    [ -d "\$DIR" ] || return 0
    cat > "\$DIR/isolinux.cfg" << SYSLINUX
UI vesamenu.c32
DEFAULT live
TIMEOUT 150
PROMPT 0

MENU TITLE Borne Multiservices - Menu de demarrage

LABEL live
  MENU LABEL > Demarrer (menu de selection)
  MENU DEFAULT
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img \${BOOT_PARAMS}

LABEL install
  MENU LABEL > Installer sur le disque (kiosque persistant)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img \${BOOT_PARAMS} installer=1

LABEL live-safe
  MENU LABEL > Demarrer - Sans echec (nomodeset)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img \${BOOT_PARAMS} nomodeset
SYSLINUX
    echo "# replaced by custom boot menu" > "\$DIR/live.cfg"
    echo "[hook] syslinux patche dans \$DIR"
}

for DIR in binary/isolinux binary/boot/isolinux; do
    write_syslinux "\$DIR"
done

write_grub() {
    local CFG="\$1"
    [ -f "\$CFG" ] || { echo "[hook] \$CFG absent, ignore"; return 0; }
    cat > "\$CFG" << GRUBMENU
set default=0
set timeout=15

if [ x\\\$feature_all_video_module = xy ]; then
  insmod all_video
fi

menuentry "Demarrer (menu de selection)" {
  linux /live/vmlinuz \${BOOT_PARAMS}
  initrd /live/initrd.img
}

menuentry "Installer sur le disque (kiosque persistant)" {
  linux /live/vmlinuz \${BOOT_PARAMS} installer=1
  initrd /live/initrd.img
}

menuentry "Demarrer - Sans echec (nomodeset)" {
  linux /live/vmlinuz \${BOOT_PARAMS} nomodeset
  initrd /live/initrd.img
}
GRUBMENU
    echo "[hook] grub patche dans \$CFG"
}

for CFG in binary/boot/grub/grub.cfg \
           binary/EFI/boot/grub.cfg  \
           binary/boot/grub/x86_64-efi/grub.cfg; do
    write_grub "\$CFG"
done
HOOK
chmod +x config/hooks/normal/9999-bootmenu.hook.binary
ok "Hook 9999-bootmenu créé"

# =============================================================================
# Build de l'ISO
# =============================================================================
step "Lancement de la build live-build (20-40 min)..."
lb build 2>&1 | tee /tmp/lb-build.log

step "Récupération de l'ISO générée..."
ISO_FOUND=""
for candidate in live-image-amd64.hybrid.iso live-image-amd64.iso binary.hybrid.iso; do
    [[ -f "$candidate" ]] && { ISO_FOUND="$candidate"; break; }
done
[[ -n "$ISO_FOUND" ]] || err "ISO introuvable après la build. Consultez /tmp/lb-build.log"
ISO_SIZE=$(du -h "$ISO_FOUND" | cut -f1)
ok "ISO : $ISO_FOUND ($ISO_SIZE)"

step "Finalisation..."
mv "$ISO_FOUND" "$ISO_NAME"
ok "ISO finale : $ISO_NAME"

step "Nettoyage..."
lb clean

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo -e "${GREEN}║  🎉  BUILD TERMINÉ AVEC SUCCÈS${RESET}"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  ISO         : $ISO_NAME"
echo "║  Code retenu : code_installer/ (shadowClone, e-Broyeur, VirtuPack)"
echo "║                code/ (Bastion-Antiviral)"
echo "║  Taille      : $ISO_SIZE"
echo "║  Clavier     : AZERTY (fr)"
echo "║  Autologin   : kiosk  (sudo sans mot de passe)"
echo "║  Mot de passe Administration (menu) : 0000  (À CHANGER !)"
echo "║    -> fichier : /etc/kiosk-menu/admin.pass"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  MENU DE DÉMARRAGE (BIOS syslinux + UEFI GRUB) :             ║"
echo "║    1. Demarrer (menu de selection)                          ║"
echo "║    2. Installer sur le disque (kiosque persistant)          ║"
echo "║    3. Demarrer - Sans echec (nomodeset)                     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  APPLICATIONS DISPONIBLES DANS LE MENU :                     ║"
echo "║    - Cloneur de disque       (shadowClone)                  ║"
echo "║    - Broyeur de disque       (e-Broyeur)                    ║"
echo "║    - Machine virtuelle (P2V) (VirtuPack)                    ║"
echo "║    - Antivirus USB           (Bastion-Antiviral)             ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  PANNEAU D'ADMINISTRATION DU MENU (bouton en bas à droite) : ║"
echo "║    - Active/désactive chaque bouton du menu principal        ║"
echo "║      (bouton grisé si désactivé, ne lance plus rien).        ║"
echo "║      -> état stocké dans /etc/kiosk-menu/apps_state.json     ║"
echo "║    - Redémarrage ou extinction RÉELLE de la borne             ║"
echo "║      (systemctl reboot/poweroff en chemin absolu).           ║"
echo "║  Le retour au menu depuis une application se fait via le      ║"
echo "║  bouton Redémarrer propre à chaque application (aucune        ║"
echo "║  interception système n'est utilisée par ce wrapper).        ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Pour flasher sur une clé USB :                              ║"
echo "║    sudo dd if=$ISO_NAME of=/dev/sdX bs=4M status=progress    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
