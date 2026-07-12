#!/usr/bin/env python3
"""
main.py – Sélecteur de menu kiosque (borne tactile multi-services)

Affiche un menu plein écran permettant de choisir laquelle des 4 bornes
lancer :
    - Cloneur de disque      (shadowClone)
    - Broyeur de disque      (e-Broyeur)
    - Machine virtuelle P2V  (VirtuPack)
    - Antivirus USB          (Bastion-Antiviral)

Chaque application est lancée en sous-processus. Quand l'utilisateur quitte
l'application (bouton Quitter interne à chaque appli), le menu réapparaît
automatiquement : il n'y a jamais de retour à un bureau ou à un shell.

Le signal d'extinction ("Éteindre" / poweroff) émis par les applications
elles-mêmes n'est PAS traité ici : il est intercepté en amont par les shims
/usr/local/sbin/{poweroff,halt,shutdown} et /usr/local/bin/systemctl
installés par forgeIsoMenu64.sh, qui le convertissent en redémarrage
(systemctl reboot). Ce menu revient donc toujours au premier plan après un
redémarrage, sans jamais couper réellement l'alimentation de la borne.

Une extinction réelle (maintenance) reste possible depuis ce menu via le
bouton "Maintenance", protégé par mot de passe, qui appelle directement le
binaire système réel (chemin absolu, hors PATH, donc non intercepté).
"""

import os
import subprocess
import sys
import tkinter as tk
from tkinter import ttk, simpledialog, messagebox
import logging
import logging.handlers

LOG_DIR = "/var/log/kiosk-menu"
LOG_FILE = os.path.join(LOG_DIR, "menu.log")
CONFIG_ADMIN_PASSWORD_FILE = "/etc/kiosk-menu/admin.pass"

# Chemins absolus des binaires réels utilisés pour la maintenance,
# volontairement HORS PATH afin de ne jamais être capturés par les shims
# poweroff/halt/shutdown/systemctl installés dans /usr/local/{sbin,bin}.
REAL_SYSTEMCTL_CANDIDATES = ["/usr/bin/systemctl", "/bin/systemctl"]

APPS = [
    {
        "id": "shadowclone",
        "title": "Cloneur de disque",
        "subtitle": "Clonage bit-à-bit USB → USB",
        "command": ["/usr/local/bin/app-shadowclone"],
        "color": "#1f6feb",
    },
    {
        "id": "e-broyeur",
        "title": "Broyeur de disque",
        "subtitle": "Effacement sécurisé (HDD / SSD)",
        "command": ["/usr/local/bin/app-broyeur"],
        "color": "#d1242f",
    },
    {
        "id": "virtupack",
        "title": "Machine virtuelle",
        "subtitle": "Conversion Physique → Virtuel (P2V)",
        "command": ["/usr/local/bin/app-virtupack"],
        "color": "#8250df",
    },
    {
        "id": "bastion-antiviral",
        "title": "Antivirus USB",
        "subtitle": "Scanner antiviral (ClamAV / YARA / Avast)",
        "command": ["/usr/local/bin/app-antivirus"],
        "color": "#1a7f37",
    },
]


def setup_logging():
    os.makedirs(LOG_DIR, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        LOG_FILE, maxBytes=2_000_000, backupCount=3
    )
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[handler, logging.StreamHandler(sys.stdout)],
    )


def real_systemctl_path():
    for path in REAL_SYSTEMCTL_CANDIDATES:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


class KioskMenu:
    def __init__(self, root):
        self.root = root
        self.root.title("Sélecteur de bornes")
        self.root.configure(bg="#0d1117")
        self.root.attributes("-fullscreen", True)
        # Aucune touche ne doit permettre de sortir du kiosque.
        for seq in ("<Escape>", "<Alt-F4>", "<Alt-Tab>", "<Super_L>"):
            self.root.bind(seq, lambda e: "break")
        self.build_ui()

    def build_ui(self):
        header = tk.Label(
            self.root,
            text="Sélectionnez le service à lancer",
            font=("DejaVu Sans", 28, "bold"),
            bg="#0d1117",
            fg="#f0f6fc",
            pady=40,
        )
        header.pack(fill="x")

        grid = tk.Frame(self.root, bg="#0d1117")
        grid.pack(expand=True, fill="both", padx=60, pady=20)

        for idx, app in enumerate(APPS):
            row, col = divmod(idx, 2)
            grid.rowconfigure(row, weight=1)
            grid.columnconfigure(col, weight=1)

            btn = tk.Frame(
                grid, bg=app["color"], highlightthickness=0, bd=0
            )
            btn.grid(row=row, column=col, sticky="nsew", padx=25, pady=25)

            title_lbl = tk.Label(
                btn,
                text=app["title"],
                font=("DejaVu Sans", 24, "bold"),
                bg=app["color"],
                fg="white",
            )
            title_lbl.pack(expand=True, pady=(30, 5))

            subtitle_lbl = tk.Label(
                btn,
                text=app["subtitle"],
                font=("DejaVu Sans", 14),
                bg=app["color"],
                fg="#f0f0f0",
                wraplength=380,
                justify="center",
            )
            subtitle_lbl.pack(expand=True, pady=(0, 30))

            for widget in (btn, title_lbl, subtitle_lbl):
                widget.bind("<Button-1>", lambda e, a=app: self.launch(a))

        footer = tk.Frame(self.root, bg="#0d1117")
        footer.pack(fill="x", pady=10)

        maint_btn = tk.Button(
            footer,
            text="Maintenance",
            font=("DejaVu Sans", 12),
            command=self.maintenance_prompt,
            bg="#21262d",
            fg="#8b949e",
            relief="flat",
            padx=15,
            pady=8,
        )
        maint_btn.pack(side="right", padx=30)

    def launch(self, app):
        logging.info("Lancement demandé : %s", app["id"])
        self.root.withdraw()
        try:
            result = subprocess.run(app["command"])
            logging.info(
                "Application %s terminée (code %s)", app["id"], result.returncode
            )
        except FileNotFoundError:
            logging.error("Binaire introuvable pour %s : %s", app["id"], app["command"])
            messagebox.showerror(
                "Erreur", f"Impossible de lancer {app['title']} : binaire introuvable."
            )
        except Exception as exc:  # sécurité : ne jamais planter le menu
            logging.exception("Erreur inattendue en lançant %s : %s", app["id"], exc)
        finally:
            self.root.deiconify()
            self.root.attributes("-fullscreen", True)
            self.root.lift()
            self.root.focus_force()

    def maintenance_prompt(self):
        pwd = simpledialog.askstring(
            "Maintenance", "Mot de passe administrateur :", show="*", parent=self.root
        )
        if pwd is None:
            return
        if not self._check_admin_password(pwd):
            messagebox.showerror("Maintenance", "Mot de passe incorrect.")
            return
        self.show_maintenance_menu()

    def _check_admin_password(self, pwd):
        try:
            with open(CONFIG_ADMIN_PASSWORD_FILE, "r", encoding="utf-8") as fh:
                stored = fh.read().strip()
            return stored and pwd == stored
        except OSError:
            # Pas de mot de passe configuré : maintenance désactivée par défaut,
            # évite qu'une image mal configurée laisse l'accès grand ouvert.
            logging.warning("Fichier mot de passe admin introuvable : %s",
                             CONFIG_ADMIN_PASSWORD_FILE)
            return False

    def show_maintenance_menu(self):
        win = tk.Toplevel(self.root)
        win.title("Maintenance")
        win.configure(bg="#161b22")
        win.attributes("-topmost", True)
        win.geometry("420x220+{}+{}".format(
            self.root.winfo_screenwidth() // 2 - 210,
            self.root.winfo_screenheight() // 2 - 110,
        ))

        tk.Label(
            win, text="Mode maintenance", font=("DejaVu Sans", 16, "bold"),
            bg="#161b22", fg="#f0f6fc", pady=15,
        ).pack()

        def do_reboot():
            logging.info("Maintenance : redémarrage réel demandé")
            win.destroy()
            self._real_systemctl_action("reboot")

        def do_poweroff():
            logging.info("Maintenance : extinction réelle demandée")
            win.destroy()
            self._real_systemctl_action("poweroff")

        tk.Button(
            win, text="Redémarrer la borne", font=("DejaVu Sans", 13),
            command=do_reboot, padx=10, pady=10,
        ).pack(fill="x", padx=30, pady=6)

        tk.Button(
            win, text="Éteindre réellement la borne", font=("DejaVu Sans", 13),
            command=do_poweroff, padx=10, pady=10,
        ).pack(fill="x", padx=30, pady=6)

        tk.Button(
            win, text="Annuler", font=("DejaVu Sans", 13),
            command=win.destroy, padx=10, pady=6,
        ).pack(fill="x", padx=30, pady=10)

    def _real_systemctl_action(self, action):
        systemctl = real_systemctl_path()
        if not systemctl:
            logging.error("systemctl réel introuvable, action %s annulée", action)
            messagebox.showerror("Maintenance", "systemctl introuvable.")
            return
        subprocess.run([systemctl, action], check=False)


def main():
    setup_logging()
    logging.info("Démarrage du menu kiosque")
    root = tk.Tk()
    KioskMenu(root)
    root.mainloop()


if __name__ == "__main__":
    main()
