# Borne Multiservices

Wrapper qui fusionne quatre bornes tactiles indépendantes derrière un seul
menu de sélection, sur une seule image ISO Debian live :

| Application         | Dépôt amont | Rôle |
|---------------------|-------------|------|
| Cloneur de disque   | [shadowClone](https://github.com/Bolo101/shadowClone) | Clonage bit-à-bit USB → USB |
| Broyeur de disque   | [e-Broyeur](https://github.com/Bolo101/e-Broyeur) | Effacement sécurisé (HDD / SSD) |
| Machine virtuelle   | [VirtuPack](https://github.com/Bolo101/VirtuPack) | Conversion Physique → Virtuel (P2V) |
| Antivirus USB       | [Bastion-Antiviral](https://github.com/Bolo101/Bastion-Antiviral) | Scan antiviral (ClamAV / YARA / Avast) |

## Contenu de ce dossier

```
forgeIsoMenu64.sh      script maître : clone les 4 dépôts, construit l'ISO
menu_selector/main.py  menu Tkinter plein écran (point d'entrée de la borne)
makefile               cibles make pour lancer le script
README.md              ce document
```

## Principe

Au démarrage, la borne lance un menu plein écran avec 4 boutons. Cliquer sur
un bouton lance l'application correspondante en sous-processus ; à sa
fermeture, le menu réapparaît automatiquement.

### Panneau d'administration

Un bouton **Administration** (protégé par mot de passe, fichier
`/etc/kiosk-menu/admin.pass`, valeur par défaut `0000` à changer
impérativement après le premier déploiement) permet :

- **d'activer/désactiver chaque bouton** du menu principal. Un bouton
  désactivé apparaît grisé et ne lance plus rien au clic. L'état est
  persisté dans `/etc/kiosk-menu/apps_state.json`.
- **d'éteindre ou redémarrer réellement la borne** (`systemctl
  poweroff` / `systemctl reboot`, appelé en chemin absolu).

### Retour au menu depuis une application

Ce wrapper n'intercepte plus aucune commande système. Le retour au menu
après utilisation d'une application repose sur un bouton **Redémarrer**
propre à chaque application — à ajouter dans le code des 4 projets
eux-mêmes (hors périmètre de ce wrapper). Si une application garde son
bouton d'extinction (`poweroff` / `systemctl poweroff`) d'origine, un clic
dessus éteindra réellement la borne : pensez à le retirer ou à le remplacer
par un redémarrage lors de l'intégration du bouton Redémarrer.

## Sous-dossier de code retenu par application

Chaque dépôt amont peut contenir jusqu'à deux variantes du code :

- `code/` : pas de panneau admin protégé par mot de passe.
- `code_installer/` : panneau admin protégé par mot de passe
  (`admin_interface.py`, `config_manager.py`, etc.).

Ce wrapper retient systématiquement :

| Application | Sous-dossier utilisé |
|---|---|
| shadowClone | `code_installer/` |
| e-Broyeur | `code_installer/` |
| VirtuPack | `code_installer/` |
| Bastion-Antiviral | `code/` (contient déjà nativement l'authentification via `admin_auth.py`) |

## Spécificités techniques préservées

- **VirtuPack** : `qemu.conf` (`user`/`group` = `root`), ACL cgroup pour les
  disques amovibles courants, service `vp-libvirt-setup`, pour que
  virt-manager puisse lancer une VM stockée sur un disque externe monté en
  cours de session.
- **e-Broyeur** : aucune règle udev ne force la valeur de
  `/sys/block/*/queue/rotational`. C'est volontaire : la détection
  mécanique/SSD d'e-Broyeur (`is_ssd()` dans `disk_erase.py`) lit cet
  attribut directement et doit rester fiable.
- **Bastion-Antiviral** : hooks ClamAV (base officielle + signatures
  tierces Sanesecurity/InterServer/URLhaus), YARA (signature-base) et Avast
  Business (installation best-effort, licence à activer séparément) repris
  du script d'origine.

## Menu de démarrage

Le menu de démarrage (syslinux BIOS + GRUB UEFI) propose 3 entrées :

1. **Démarrer** (menu de sélection) — mode live normal.
2. **Installer sur le disque (kiosque persistant)** — copie (rsync) tout le
   système live sur un disque interne : les 4 applications, le menu, ClamAV/
   YARA/Avast et la configuration libvirt sont installés tels quels. Le
   système installé démarre ensuite directement sur le même menu de
   sélection (session `xfwm4`, plus robuste qu'OpenBox pour un usage
   pérenne). L'installateur (`/usr/local/bin/install-to-disk.sh`, whiptail)
   demande le disque cible, partitionne (GPT+ESP en UEFI, MBR en BIOS),
   formate, copie le système, régénère `/etc/fstab`, installe GRUB et
   bascule l'autologin sur la session installée.
3. **Démarrer - Sans échec (nomodeset)** — mode live avec pilote vidéo
   générique, utile en cas d'écran noir dû à un pilote graphique.

## Simplifications assumées

- Un seul mode d'installation, générique (rsync du système live complet),
  au lieu d'un installateur distinct par application. Cela évite de gérer
  quatre logiques d'installation différentes alors que le contenu à copier
  est strictement le même (le système live entier).
- Le pré-check réseau Avast côté machine de build (présent dans le script
  d'origine de Bastion-Antiviral) est retiré : le hook d'installation
  suffit et gère déjà tous les cas d'échec réseau proprement.

## Pré-requis (machine de build)

```
sudo apt install live-build xorriso syslinux isolinux syslinux-utils \
                 wget curl python3 unzip rsync git
```

Connexion Internet requise (clone des 4 dépôts GitHub, dépôts Debian,
dépôt Avast, signature-base).

## Utilisation

```bash
make
# ou directement :
sudo ./forgeIsoMenu64.sh

# Nettoyage
make clean       # supprime le répertoire de build live-build et les dépôts clonés
make distclean   # clean + supprime aussi l'ISO générée
```

L'ISO produite s'appelle `borne-multiservices-v1.0.iso`.

Pour flasher sur une clé USB :

```bash
sudo dd if=borne-multiservices-v1.0.iso of=/dev/sdX bs=4M status=progress
```

## Identifiants et fichiers de configuration sur la borne

| Élément | Emplacement | Valeur par défaut |
|---|---|---|
| Compte système kiosque | utilisateur `kiosk` | mot de passe `kiosk`, sudo NOPASSWD |
| Mot de passe panneau Administration (menu) | `/etc/kiosk-menu/admin.pass` | `0000` |
| État activé/désactivé des boutons | `/etc/kiosk-menu/apps_state.json` | tout activé |
| Journal du menu | `/var/log/kiosk-menu/menu.log` | — |

**À faire après le premier déploiement : changer le mot de passe du compte
`kiosk` et le contenu de `/etc/kiosk-menu/admin.pass`.**
