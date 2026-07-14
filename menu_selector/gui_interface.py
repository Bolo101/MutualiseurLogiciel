#!/usr/bin/env python3
"""
gui_interface.py – Interface principale du menu kiosque.
"""

from __future__ import annotations

import json
import logging
import logging.handlers
import os
import subprocess
import sys
import tkinter as tk
from tkinter import messagebox

from admin_interface import open_admin_panel

LOG_DIR = "/var/log/kiosk-menu"
LOG_FILE = os.path.join(LOG_DIR, "menu.log")
APPS_STATE_FILE = "/etc/kiosk-menu/apps_state.json"

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


def setup_logging() -> None:
    os.makedirs(LOG_DIR, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        LOG_FILE,
        maxBytes=2_000_000,
        backupCount=3,
    )
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[handler, logging.StreamHandler(sys.stdout)],
    )


def load_apps_state() -> dict[str, bool]:
    """Renvoie {app_id: bool_actif}. Par défaut tout est actif."""
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


class KioskMenu:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Sélecteur de bornes")
        self.root.configure(bg="#0d1117")
        self.root.attributes("-fullscreen", True)

        for seq in ("<F11>", "<Escape>", "<Alt-F4>", "<Control-q>"):
            self.root.bind(seq, lambda _e: "break")

        self.apps_state = load_apps_state()
        self.tiles: dict[str, dict[str, tk.Widget]] = {}
        self.build_ui()

    def build_ui(self) -> None:
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
            command=lambda: open_admin_panel(self.root, self.refresh_tiles),
            bg="#21262d",
            fg="#8b949e",
            relief="flat",
            padx=15,
            pady=8,
        )
        admin_btn.pack(side="right", padx=30)

    def build_tile(self, grid: tk.Frame, app: dict, row: int, col: int) -> None:
        enabled = self.apps_state.get(app["id"], True)
        bg_color = app["color"] if enabled else DISABLED_BG
        fg_color = "white" if enabled else DISABLED_FG

        btn = tk.Frame(grid, bg=bg_color, highlightthickness=0, bd=0)
        btn.grid(row=row, column=col, sticky="nsew", padx=25, pady=25)

        title_lbl = tk.Label(
            btn,
            text=app["title"],
            font=("DejaVu Sans", 24, "bold"),
            bg=bg_color,
            fg=fg_color,
        )
        title_lbl.pack(expand=True, pady=(30, 5))

        subtitle_text = (
            app["subtitle"]
            if enabled
            else "Indisponible (désactivé par l'administrateur)"
        )
        subtitle_lbl = tk.Label(
            btn,
            text=subtitle_text,
            font=("DejaVu Sans", 14),
            bg=bg_color,
            fg=fg_color if enabled else DISABLED_FG,
            wraplength=380,
            justify="center",
        )
        subtitle_lbl.pack(expand=True, pady=(0, 30))

        self.tiles[app["id"]] = {
            "frame": btn,
            "title": title_lbl,
            "subtitle": subtitle_lbl,
        }

        if enabled:
            for widget in (btn, title_lbl, subtitle_lbl):
                widget.bind("<Button-1>", lambda _e, a=app: self.launch(a))

    def refresh_tiles(self) -> None:
        self.apps_state = load_apps_state()
        self.build_ui()

    def launch(self, app: dict) -> None:
        if not self.apps_state.get(app["id"], True):
            return

        logging.info("Lancement demandé : %s", app["id"])
        self.root.withdraw()
        try:
            result = subprocess.run(app["command"])
            logging.info(
                "Application %s terminée (code %s)",
                app["id"],
                result.returncode,
            )
        except FileNotFoundError:
            logging.error(
                "Binaire introuvable pour %s : %s",
                app["id"],
                app["command"],
            )
            messagebox.showerror(
                "Erreur",
                f"Impossible de lancer {app['title']} : binaire introuvable.",
                parent=self.root,
            )
        except Exception as exc:
            logging.exception("Erreur inattendue en lançant %s : %s", app["id"], exc)
        finally:
            self.root.deiconify()
            self.root.attributes("-fullscreen", True)
            self.root.lift()
            self.root.focus_force()


def run_gui() -> None:
    setup_logging()
    logging.info("Démarrage du menu kiosque")
    root = tk.Tk()
    KioskMenu(root)
    root.mainloop()