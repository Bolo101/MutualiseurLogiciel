#!/usr/bin/env python3
"""
admin_interface.py – Authentification et panneau d'administration du menu kiosque.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import tkinter as tk
from tkinter import messagebox, simpledialog
from typing import Callable, Optional

from secure_credentials import SecureCredentialStore

CONFIG_DIR = "/etc/kiosk-menu"
ADMIN_CRED_FILE = os.path.join(CONFIG_DIR, "admin.cred")
APPS_STATE_FILE = os.path.join(CONFIG_DIR, "apps_state.json")

REAL_SYSTEMCTL_CANDIDATES = ["/usr/bin/systemctl", "/bin/systemctl"]

APPS = [
    {
        "id": "shadowclone",
        "title": "Cloneur de disque",
    },
    {
        "id": "e-broyeur",
        "title": "Broyeur de disque",
    },
    {
        "id": "virtupack",
        "title": "Machine virtuelle",
    },
    {
        "id": "bastion-antiviral",
        "title": "Antivirus USB",
    },
]

_store = SecureCredentialStore(
    path=ADMIN_CRED_FILE,
    default_password="0000",
)


def real_systemctl_path() -> str | None:
    for path in REAL_SYSTEMCTL_CANDIDATES:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def load_apps_state() -> dict[str, bool]:
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


def save_apps_state(state: dict[str, bool]) -> bool:
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


def _prompt_first_password(parent: tk.Widget) -> bool:
    while True:
        new_password = simpledialog.askstring(
            "Premier démarrage",
            "Aucun mot de passe administrateur n'est défini.\n"
            "Choisissez un mot de passe administrateur :",
            show="•",
            parent=parent,
        )
        if new_password is None:
            return False

        confirm = simpledialog.askstring(
            "Confirmation",
            "Confirmez le mot de passe administrateur :",
            show="•",
            parent=parent,
        )
        if confirm is None:
            return False

        if new_password != confirm:
            messagebox.showerror(
                "Administration",
                "Les mots de passe ne correspondent pas.",
                parent=parent,
            )
            continue

        ok, message = _store.force_set_password(new_password)
        if not ok:
            messagebox.showerror("Administration", message, parent=parent)
            continue

        messagebox.showinfo(
            "Administration",
            "Mot de passe administrateur enregistré.",
            parent=parent,
        )
        return True


def _prompt_password(parent: tk.Widget) -> Optional[str]:
    return simpledialog.askstring(
        "Administration",
        "Mot de passe administrateur :",
        show="•",
        parent=parent,
    )


class AdminPanel(tk.Toplevel):
    def __init__(self, parent: tk.Widget, on_state_changed: Optional[Callable[[], None]] = None) -> None:
        super().__init__(parent)
        self.parent = parent
        self.on_state_changed = on_state_changed
        self.apps_state = load_apps_state()

        self.title("Administration")
        self.configure(bg="#161b22")
        self.attributes("-topmost", True)
        self.grab_set()

        width, height = 520, 640
        self.geometry(
            "{}x{}+{}+{}".format(
                width,
                height,
                parent.winfo_screenwidth() // 2 - width // 2,
                parent.winfo_screenheight() // 2 - height // 2,
            )
        )

        self._build_ui()

    def _build_ui(self) -> None:
        tk.Label(
            self,
            text="Panneau d'administration",
            font=("DejaVu Sans", 18, "bold"),
            bg="#161b22",
            fg="#f0f6fc",
            pady=15,
        ).pack()

        tk.Label(
            self,
            text="Applications disponibles sur le menu principal",
            font=("DejaVu Sans", 13, "bold"),
            bg="#161b22",
            fg="#f0f6fc",
        ).pack(pady=(10, 5), anchor="w", padx=25)

        self.check_vars: dict[str, tk.BooleanVar] = {}
        for app in APPS:
            var = tk.BooleanVar(value=self.apps_state.get(app["id"], True))
            self.check_vars[app["id"]] = var
            cb = tk.Checkbutton(
                self,
                text=app["title"],
                variable=var,
                font=("DejaVu Sans", 13),
                bg="#161b22",
                fg="#f0f6fc",
                selectcolor="#0d1117",
                activebackground="#161b22",
                activeforeground="#f0f6fc",
                anchor="w",
            )
            cb.pack(fill="x", padx=40, pady=2)

        tk.Button(
            self,
            text="Enregistrer les activations",
            font=("DejaVu Sans", 12, "bold"),
            command=self._save_state,
            bg="#238636",
            fg="white",
            relief="flat",
            padx=10,
            pady=8,
        ).pack(fill="x", padx=40, pady=(10, 20))

        tk.Label(
            self,
            text="Sécurité",
            font=("DejaVu Sans", 13, "bold"),
            bg="#161b22",
            fg="#f0f6fc",
        ).pack(pady=(5, 5), anchor="w", padx=25)

        tk.Button(
            self,
            text="Changer le mot de passe administrateur",
            font=("DejaVu Sans", 13),
            command=self._change_password,
            padx=10,
            pady=10,
        ).pack(fill="x", padx=40, pady=4)

        tk.Label(
            self,
            text="Alimentation de la borne",
            font=("DejaVu Sans", 13, "bold"),
            bg="#161b22",
            fg="#f0f6fc",
        ).pack(pady=(15, 5), anchor="w", padx=25)

        tk.Button(
            self,
            text="Redémarrer la borne",
            font=("DejaVu Sans", 13),
            command=self._do_reboot,
            padx=10,
            pady=10,
        ).pack(fill="x", padx=40, pady=4)

        tk.Button(
            self,
            text="Éteindre réellement la borne",
            font=("DejaVu Sans", 13),
            command=self._do_poweroff,
            bg="#8b1a1a",
            fg="white",
            padx=10,
            pady=10,
        ).pack(fill="x", padx=40, pady=4)

        tk.Button(
            self,
            text="Fermer",
            font=("DejaVu Sans", 12),
            command=self.destroy,
            padx=10,
            pady=6,
        ).pack(fill="x", padx=40, pady=(20, 10))

    def _save_state(self) -> None:
        new_state = {app_id: var.get() for app_id, var in self.check_vars.items()}
        if save_apps_state(new_state):
            logging.info("État des applications enregistré : %s", new_state)
            messagebox.showinfo(
                "Administration",
                "Configuration enregistrée.",
                parent=self,
            )
            if self.on_state_changed:
                self.on_state_changed()
        else:
            messagebox.showerror(
                "Administration",
                "Impossible d'écrire la configuration (droits insuffisants ?).",
                parent=self,
            )

    def _change_password(self) -> None:
        old_password = simpledialog.askstring(
            "Ancien mot de passe",
            "Mot de passe actuel :",
            show="•",
            parent=self,
        )
        if old_password is None:
            return

        new_password = simpledialog.askstring(
            "Nouveau mot de passe",
            "Nouveau mot de passe :",
            show="•",
            parent=self,
        )
        if not new_password:
            return

        confirm = simpledialog.askstring(
            "Confirmation",
            "Confirmez le nouveau mot de passe :",
            show="•",
            parent=self,
        )
        if new_password != confirm:
            messagebox.showerror(
                "Administration",
                "Les mots de passe ne correspondent pas.",
                parent=self,
            )
            return

        ok, message = _store.change_password(old_password, new_password)
        if not ok:
            messagebox.showerror("Administration", message, parent=self)
            return

        messagebox.showinfo(
            "Administration",
            "Mot de passe modifié avec succès.",
            parent=self,
        )

    def _real_systemctl_action(self, action: str) -> None:
        systemctl = real_systemctl_path()
        if not systemctl:
            logging.error("systemctl réel introuvable, action %s annulée", action)
            messagebox.showerror("Administration", "systemctl introuvable.", parent=self)
            return
        subprocess.run([systemctl, action], check=False)

    def _do_reboot(self) -> None:
        logging.info("Administration : redémarrage réel demandé")
        self.destroy()
        self._real_systemctl_action("reboot")

    def _do_poweroff(self) -> None:
        if not messagebox.askyesno(
            "Confirmation",
            "Confirmer l'extinction RÉELLE de la borne ?",
            parent=self,
        ):
            return
        logging.info("Administration : extinction réelle demandée")
        self.destroy()
        self._real_systemctl_action("poweroff")


def open_admin_panel(parent: tk.Widget, on_state_changed: Optional[Callable[[], None]] = None) -> None:
    if not os.path.exists(ADMIN_CRED_FILE):
        if not _prompt_first_password(parent):
            return

    password = _prompt_password(parent)
    if password is None:
        return

    ok, wait = _store.verify(password)

    if wait > 0:
        messagebox.showerror(
            "Administration",
            f"Trop de tentatives. Réessayez dans {wait} seconde(s).",
            parent=parent,
        )
        return

    if not ok:
        messagebox.showerror(
            "Administration",
            "Mot de passe incorrect.",
            parent=parent,
        )
        return

    AdminPanel(parent, on_state_changed=on_state_changed)