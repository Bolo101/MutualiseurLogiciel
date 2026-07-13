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
l'application, le menu réapparaît automatiquement.

Panneau d'administration (protégé par mot de passe) :
    - Extinction réelle de la borne (poweroff) et redémarrage réel (reboot),
      via systemctl, en chemin absolu.
    - Activation / désactivation de chaque bouton du menu principal. Un
      bouton désactivé apparaît grisé sur le menu principal et ne lance
      plus rien au clic.

Le redémarrage "retour au menu" demandé par un utilisateur normal se fait
désormais depuis un bouton Redémarrer propre à chaque application (ajouté
directement dans le code des 4 applications) — ce menu ne dépend plus
d'aucune interception de commande système (poweroff/systemctl).
"""

import json
import os
import subprocess
import sys
import tkinter as tk
from tkinter import simpledialog, messagebox
import logging
import logging.handlers

LOG_DIR = "/var/log/kiosk-menu"
LOG_FILE = os.path.join(LOG_DIR, "menu.log")
ADMIN_PASSWORD_FILE = "/etc/kiosk-menu/admin.pass"
APPS_STATE_FILE = "/etc/kiosk-menu/apps_state.json"

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

DISABLED_BG = "#30363d"
DISABLED_FG = "#6e7681"


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


def load_apps_state():
    """Renvoie {app_id: bool_actif}. Par défaut tout est actif si le fichier
    est absent, illisible, ou incomplet (nouvelle appli jamais configurée)."""
    state = {app["id"]: True for app in APPS}
    try:
        with open(APPS_STATE_FILE, "r", encoding="utf-8") as fh:
            saved = json.load(fh)
        for app_id in state:
            if app_id in saved:
                state[app_id] = bool(saved[app_id])
    except (OSError, ValueError):
        pass
    return state


def save_apps_state(state):
    try:
        os.makedirs(os.path.dirname(APPS_STATE_FILE), exist_ok=True)
        tmp_path = APPS_STATE_FILE + ".tmp"
        with open(tmp_path, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2, ensure_ascii=False)
        os.replace(tmp_path, APPS_STATE_FILE)
        return True
    except OSError as exc:
        logging.error("Impossible d'écrire %s : %s", APPS_STATE_FILE, exc)
        return False


class KioskMenu:
    def __init__(self, root):
        self.root = root
        self.root.title("Sélecteur de bornes")
        self.root.configure(bg="#0d1117")
        self.root.attributes("-fullscreen", True)
        for seq in ("<Escape>", "<Alt-F4>", "<Alt-Tab>", "<Super_L>"):
            self.root.bind(seq, lambda e: "break")

        self.apps_state = load_apps_state()
        self.tiles = {}  # app_id -> dict of widgets
        self.build_ui()

    # ── Interface principale ─────────────────────────────────────────────
    def build_ui(self):
        for widget in self.root.winfo_children():
            widget.destroy()

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
            self.build_tile(grid, app, row, col)

        footer = tk.Frame(self.root, bg="#0d1117")
        footer.pack(fill="x", pady=10)

        admin_btn = tk.Button(
            footer,
            text="Administration",
            font=("DejaVu Sans", 12),
            command=self.admin_prompt,
            bg="#21262d",
            fg="#8b949e",
            relief="flat",
            padx=15,
            pady=8,
        )
        admin_btn.pack(side="right", padx=30)

    def build_tile(self, grid, app, row, col):
        enabled = self.apps_state.get(app["id"], True)
        bg_color = app["color"] if enabled else DISABLED_BG
        fg_color = "white" if enabled else DISABLED_FG

        btn = tk.Frame(grid, bg=bg_color, highlightthickness=0, bd=0)
        btn.grid(row=row, column=col, sticky="nsew", padx=25, pady=25)

        title_lbl = tk.Label(
            btn, text=app["title"], font=("DejaVu Sans", 24, "bold"),
            bg=bg_color, fg=fg_color,
        )
        title_lbl.pack(expand=True, pady=(30, 5))

        subtitle_text = app["subtitle"] if enabled else "Indisponible (désactivé par l'administrateur)"
        subtitle_lbl = tk.Label(
            btn, text=subtitle_text, font=("DejaVu Sans", 14),
            bg=bg_color, fg=fg_color if enabled else DISABLED_FG,
            wraplength=380, justify="center",
        )
        subtitle_lbl.pack(expand=True, pady=(0, 30))

        self.tiles[app["id"]] = {
            "frame": btn, "title": title_lbl, "subtitle": subtitle_lbl,
        }

        if enabled:
            for widget in (btn, title_lbl, subtitle_lbl):
                widget.bind("<Button-1>", lambda e, a=app: self.launch(a))
        # Si désactivé : aucun bind, le clic ne fait rien.

    def refresh_tiles(self):
        """Recharge l'état actif/inactif et redessine sans tout reconstruire."""
        self.apps_state = load_apps_state()
        self.build_ui()

    # ── Lancement d'une application ──────────────────────────────────────
    def launch(self, app):
        if not self.apps_state.get(app["id"], True):
            return  # sécurité supplémentaire, ne devrait pas arriver
        logging.info("Lancement demandé : %s", app["id"])
        self.root.withdraw()
        try:
            result = subprocess.run(app["command"])
            logging.info("Application %s terminée (code %s)", app["id"], result.returncode)
        except FileNotFoundError:
            logging.error("Binaire introuvable pour %s : %s", app["id"], app["command"])
            messagebox.showerror("Erreur", f"Impossible de lancer {app['title']} : binaire introuvable.")
        except Exception as exc:
            logging.exception("Erreur inattendue en lançant %s : %s", app["id"], exc)
        finally:
            self.root.deiconify()
            self.root.attributes("-fullscreen", True)
            self.root.lift()
            self.root.focus_force()

    # ── Panneau d'administration ──────────────────────────────────────────
    def admin_prompt(self):
        pwd = simpledialog.askstring(
            "Administration", "Mot de passe administrateur :", show="*", parent=self.root
        )
        if pwd is None:
            return
        if not self._check_admin_password(pwd):
            messagebox.showerror("Administration", "Mot de passe incorrect.")
            return
        self.show_admin_panel()

    def _check_admin_password(self, pwd):
        try:
            with open(ADMIN_PASSWORD_FILE, "r", encoding="utf-8") as fh:
                stored = fh.read().strip()
            return bool(stored) and pwd == stored
        except OSError:
            logging.warning("Fichier mot de passe admin introuvable : %s", ADMIN_PASSWORD_FILE)
            return False

    def show_admin_panel(self):
        win = tk.Toplevel(self.root)
        win.title("Administration")
        win.configure(bg="#161b22")
        win.attributes("-topmost", True)
        win.grab_set()  # modal : bloque le menu principal tant que la fenêtre est ouverte

        w, h = 520, 560
        win.geometry("{}x{}+{}+{}".format(
            w, h,
            self.root.winfo_screenwidth() // 2 - w // 2,
            self.root.winfo_screenheight() // 2 - h // 2,
        ))

        tk.Label(
            win, text="Panneau d'administration", font=("DejaVu Sans", 18, "bold"),
            bg="#161b22", fg="#f0f6fc", pady=15,
        ).pack()

        # -- Section activation / désactivation des applications --
        tk.Label(
            win, text="Applications disponibles sur le menu principal",
            font=("DejaVu Sans", 13, "bold"), bg="#161b22", fg="#f0f6fc",
        ).pack(pady=(10, 5), anchor="w", padx=25)

        check_vars = {}
        for app in APPS:
            var = tk.BooleanVar(value=self.apps_state.get(app["id"], True))
            check_vars[app["id"]] = var
            cb = tk.Checkbutton(
                win, text=app["title"], variable=var,
                font=("DejaVu Sans", 13), bg="#161b22", fg="#f0f6fc",
                selectcolor="#0d1117", activebackground="#161b22",
                activeforeground="#f0f6fc", anchor="w",
            )
            cb.pack(fill="x", padx=40, pady=2)

        def save_state():
            new_state = {app_id: var.get() for app_id, var in check_vars.items()}
            if save_apps_state(new_state):
                logging.info("État des applications enregistré : %s", new_state)
                messagebox.showinfo("Administration", "Configuration enregistrée.", parent=win)
                win.destroy()
                self.refresh_tiles()
            else:
                messagebox.showerror(
                    "Administration",
                    "Impossible d'écrire la configuration (droits insuffisants ?).",
                    parent=win,
                )

        tk.Button(
            win, text="Enregistrer les activations", font=("DejaVu Sans", 12, "bold"),
            command=save_state, bg="#238636", fg="white", relief="flat",
            padx=10, pady=8,
        ).pack(fill="x", padx=40, pady=(10, 20))

        # -- Section alimentation --
        tk.Label(
            win, text="Alimentation de la borne", font=("DejaVu Sans", 13, "bold"),
            bg="#161b22", fg="#f0f6fc",
        ).pack(pady=(5, 5), anchor="w", padx=25)

        def do_reboot():
            logging.info("Administration : redémarrage réel demandé")
            win.destroy()
            self._real_systemctl_action("reboot")

        def do_poweroff():
            if not messagebox.askyesno(
                "Confirmation",
                "Confirmer l'extinction RÉELLE de la borne ?",
                parent=win,
            ):
                return
            logging.info("Administration : extinction réelle demandée")
            win.destroy()
            self._real_systemctl_action("poweroff")

        tk.Button(
            win, text="Redémarrer la borne", font=("DejaVu Sans", 13),
            command=do_reboot, padx=10, pady=10,
        ).pack(fill="x", padx=40, pady=4)

        tk.Button(
            win, text="Éteindre réellement la borne", font=("DejaVu Sans", 13),
            command=do_poweroff, bg="#8b1a1a", fg="white", padx=10, pady=10,
        ).pack(fill="x", padx=40, pady=4)

        tk.Button(
            win, text="Fermer", font=("DejaVu Sans", 12),
            command=win.destroy, padx=10, pady=6,
        ).pack(fill="x", padx=40, pady=(20, 10))

    def _real_systemctl_action(self, action):
        systemctl = real_systemctl_path()
        if not systemctl:
            logging.error("systemctl réel introuvable, action %s annulée", action)
            messagebox.showerror("Administration", "systemctl introuvable.")
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
