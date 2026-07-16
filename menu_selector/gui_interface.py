#!/usr/bin/env python3
"""
gui_interface.py – Interface principale du menu kiosque.

Design pensé pour donner envie d'interagir sur une borne publique :
  - Cartes arrondies avec icône vectorielle propre à chaque service (repère
    visuel rapide, indépendant de la lecture du texte).
  - Ombre portée + halo pulsé discret : signale "ceci est cliquable" et attire
    l'œil sans être agressif (mouvement lent = attention périphérique).
  - Retour immédiat au toucher (assombrissement au clic) : confirme la prise
    en compte de l'appui avant même le lancement de l'application, ce qui
    rassure sur un écran tactile public.
  - En-tête chaleureux, au ton personnel, avec horloge vivante : une horloge
    qui avance rassure que le système est "vivant" et prêt à répondre.
  - Bande de couleur en haut qui unifie visuellement les 4 services.
"""

from __future__ import annotations

import colorsys
import json
import logging
import logging.handlers
import math
import os
import subprocess
import sys
import time
import tkinter as tk
from tkinter import messagebox

from admin_interface import open_admin_panel

LOG_DIR = "/var/log/kiosk-menu"
LOG_FILE = os.path.join(LOG_DIR, "menu.log")
APPS_STATE_FILE = "/etc/kiosk-menu/apps_state.json"

BG_COLOR = "#0b0e14"
HEADER_FG = "#f0f6fc"
MUTED_FG = "#8b949e"

APPS = [
    {
        "id": "shadowclone",
        "title": "Cloneur de disque",
        "subtitle": "Dupliquez un disque, en toute simplicité",
        "command": ["/usr/local/bin/app-shadowclone"],
        "color": "#1f6feb",
    },
    {
        "id": "e-broyeur",
        "title": "Broyeur de disque",
        "subtitle": "Effacement sécurisé et définitif (HDD / SSD)",
        "command": ["/usr/local/bin/app-broyeur"],
        "color": "#d1242f",
    },
    {
        "id": "virtupack",
        "title": "Machine virtuelle",
        "subtitle": "Transformez un poste physique en machine virtuelle",
        "command": ["/usr/local/bin/app-virtupack"],
        "color": "#8250df",
    },
    {
        "id": "bastion-antiviral",
        "title": "Antivirus USB",
        "subtitle": "Scannez une clé en toute confiance",
        "command": ["/usr/local/bin/app-antivirus"],
        "color": "#1a7f37",
    },
]

DISABLED_BG = "#30363d"
DISABLED_FG = "#6e7681"


# ═════════════════════════════════════════════════════════════════════════════
# Utilitaires couleur
# ═════════════════════════════════════════════════════════════════════════════
def _hex_to_rgb(hexcolor: str) -> tuple[int, int, int]:
    hexcolor = hexcolor.lstrip("#")
    return tuple(int(hexcolor[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore


def _rgb_to_hex(rgb: tuple[float, float, float]) -> str:
    return "#%02x%02x%02x" % tuple(max(0, min(255, int(c))) for c in rgb)


def _adjust_brightness(hexcolor: str, factor: float) -> str:
    """factor < 1 assombrit, factor > 1 éclaircit (luminosité HLS)."""
    r, g, b = _hex_to_rgb(hexcolor)
    h, l, s = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
    l = max(0.0, min(1.0, l * factor))
    r, g, b = colorsys.hls_to_rgb(h, l, s)
    return _rgb_to_hex((r * 255, g * 255, b * 255))


# ═════════════════════════════════════════════════════════════════════════════
# Formes arrondies + icônes vectorielles (aucune dépendance à des fichiers image
# ou à une police d'émojis : rendu garanti identique sur toute borne)
# ═════════════════════════════════════════════════════════════════════════════
def _rounded_points(x1, y1, x2, y2, radius):
    return [
        x1 + radius, y1,
        x2 - radius, y1,
        x2, y1,
        x2, y1 + radius,
        x2, y2 - radius,
        x2, y2,
        x2 - radius, y2,
        x1 + radius, y2,
        x1, y2,
        x1, y2 - radius,
        x1, y1 + radius,
        x1, y1,
    ]


def draw_rounded_rect(canvas: tk.Canvas, x1, y1, x2, y2, radius=24, **kwargs):
    radius = max(2, min(radius, (x2 - x1) / 2, (y2 - y1) / 2))
    return canvas.create_polygon(
        _rounded_points(x1, y1, x2, y2, radius), smooth=True, **kwargs
    )


def _icon_clone(c: tk.Canvas, cx, cy, size, color):
    w, h = size * 0.95, size * 0.55
    draw_rounded_rect(c, cx - w * 0.62, cy - h / 2, cx - w * 0.06, cy + h / 2,
                       radius=8, outline=color, width=3, fill="")
    c.create_oval(cx - w * 0.52, cy - 4, cx - w * 0.44, cy + 4, fill=color, outline="")
    draw_rounded_rect(c, cx + w * 0.06, cy - h / 2, cx + w * 0.62, cy + h / 2,
                       radius=8, outline=color, width=3, fill="")
    c.create_oval(cx + w * 0.16, cy - 4, cx + w * 0.24, cy + 4, fill=color, outline="")
    c.create_line(cx - w * 0.05, cy, cx + w * 0.05, cy,
                  fill=color, width=3, arrow=tk.LAST, arrowshape=(10, 12, 5))


def _icon_shred(c: tk.Canvas, cx, cy, size, color):
    top_w = size * 0.55
    body_top = cy - size * 0.10
    body_bottom = cy + size * 0.42
    c.create_line(cx - top_w / 2 - 6, body_top, cx + top_w / 2 + 6, body_top,
                  fill=color, width=3)
    c.create_rectangle(cx - 9, body_top - 12, cx + 9, body_top, outline=color, width=3)
    c.create_polygon(
        cx - top_w / 2, body_top,
        cx + top_w / 2, body_top,
        cx + top_w / 2 - 7, body_bottom,
        cx - top_w / 2 + 7, body_bottom,
        outline=color, width=3, fill="", smooth=False,
    )
    for dx in (-0.16, 0, 0.16):
        c.create_line(cx + dx * size, body_top + 8, cx + dx * size, body_bottom - 8,
                      fill=color, width=2)


def _icon_monitor(c: tk.Canvas, cx, cy, size, color):
    w, h = size * 0.85, size * 0.52
    draw_rounded_rect(c, cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2,
                       radius=6, outline=color, width=3, fill="")
    c.create_line(cx - w * 0.28, cy - h * 0.12, cx + w * 0.05, cy - h * 0.12,
                  fill=color, width=2)
    c.create_line(cx - w * 0.28, cy + h * 0.12, cx + w * 0.20, cy + h * 0.12,
                  fill=color, width=2)
    c.create_rectangle(cx - 7, cy + h / 2, cx + 7, cy + h / 2 + 10, outline=color, width=3)
    c.create_line(cx - 18, cy + h / 2 + 10, cx + 18, cy + h / 2 + 10, fill=color, width=3)


def _icon_shield(c: tk.Canvas, cx, cy, size, color):
    w, h = size * 0.62, size * 0.8
    top = cy - h / 2
    points = [
        cx, top,
        cx + w / 2, top + h * 0.16,
        cx + w / 2, top + h * 0.55,
        cx, top + h,
        cx - w / 2, top + h * 0.55,
        cx - w / 2, top + h * 0.16,
    ]
    c.create_polygon(points, outline=color, width=3, fill="", smooth=False)
    c.create_line(cx - w * 0.22, top + h * 0.50, cx - w * 0.02, top + h * 0.68,
                  fill=color, width=3)
    c.create_line(cx - w * 0.02, top + h * 0.68, cx + w * 0.28, top + h * 0.32,
                  fill=color, width=3)


ICON_DRAW = {
    "shadowclone": _icon_clone,
    "e-broyeur": _icon_shred,
    "virtupack": _icon_monitor,
    "bastion-antiviral": _icon_shield,
}


# ═════════════════════════════════════════════════════════════════════════════
# Tuile d'application (carte canvas : ombre, halo pulsé, icône, appui/survol)
# ═════════════════════════════════════════════════════════════════════════════
class AppTile(tk.Frame):
    PRESS_FACTOR = 0.72
    HOVER_FACTOR = 1.15
    PULSE_STEPS = 48
    PULSE_DELAY_MS = 60

    def __init__(self, parent, app, enabled, on_click):
        super().__init__(parent, bg=BG_COLOR)
        self.app = app
        self.enabled = enabled
        self.on_click = on_click
        self._pressed = False
        self._hover = False
        self._pulse_phase = 0
        self._alive = True

        self.canvas = tk.Canvas(self, bg=BG_COLOR, highlightthickness=0, bd=0)
        self.canvas.pack(fill="both", expand=True)
        self.canvas.bind("<Configure>", lambda _e: self._draw())
        self.bind("<Destroy>", self._on_destroy)

        if self.enabled:
            self.canvas.bind("<ButtonPress-1>", self._on_press)
            self.canvas.bind("<ButtonRelease-1>", self._on_release)
            self.canvas.bind("<Enter>", self._on_enter)
            self.canvas.bind("<Leave>", self._on_leave)
            self.after(20, self._pulse)

    def _on_destroy(self, _e=None):
        self._alive = False

    def _on_enter(self, _e):
        self._hover = True
        self._draw()

    def _on_leave(self, _e):
        self._hover = False
        self._pressed = False
        self._draw()

    def _on_press(self, _e):
        self._pressed = True
        self._draw()

    def _on_release(self, event):
        was_pressed = self._pressed
        self._pressed = False
        self._draw()
        w, h = self.canvas.winfo_width(), self.canvas.winfo_height()
        if was_pressed and 0 <= event.x <= w and 0 <= event.y <= h:
            self.on_click(self.app)

    def _pulse(self):
        if not self._alive:
            return
        self._pulse_phase = (self._pulse_phase + 1) % self.PULSE_STEPS
        self._draw()
        self.after(self.PULSE_DELAY_MS, self._pulse)

    def _current_fill(self) -> str:
        base = self.app["color"] if self.enabled else DISABLED_BG
        if not self.enabled:
            return base
        if self._pressed:
            return _adjust_brightness(base, self.PRESS_FACTOR)
        if self._hover:
            return _adjust_brightness(base, self.HOVER_FACTOR)
        return base

    def _draw(self):
        c = self.canvas
        w, h = c.winfo_width(), c.winfo_height()
        if w < 20 or h < 20:
            return
        c.delete("all")

        fill = self._current_fill()

        # Ombre portée (donne du relief, suggère "objet posé / cliquable")
        draw_rounded_rect(c, 8, 12, w - 4, h - 2, radius=30, fill="#05070a", outline="")

        # Halo pulsé discret (respiration lente : attire l'œil sans fatiguer)
        if self.enabled:
            pulse = (math.sin(self._pulse_phase / self.PULSE_STEPS * 2 * math.pi) + 1) / 2
            glow_width = 2 + pulse * 2.5
            draw_rounded_rect(
                c, 2, 6, w - 8, h - 8, radius=30,
                outline=_adjust_brightness(fill, 1.35), width=glow_width, fill="",
            )

        # Carte principale
        draw_rounded_rect(c, 0, 0, w - 12, h - 12, radius=30, fill=fill, outline="")

        cx = (w - 12) / 2
        card_h = h - 12
        icon_color = "#ffffff" if self.enabled else DISABLED_FG
        icon_size = min(w - 12, card_h) * 0.32
        draw_fn = ICON_DRAW.get(self.app["id"])
        if draw_fn:
            draw_fn(c, cx, card_h * 0.32, icon_size, icon_color)

        title_color = "#ffffff" if self.enabled else DISABLED_FG
        c.create_text(
            cx, card_h * 0.62, text=self.app["title"],
            font=("DejaVu Sans", 22, "bold"), fill=title_color,
        )

        subtitle = self.app["subtitle"] if self.enabled else "Indisponible (désactivé par l'administrateur)"
        sub_color = "#f4f4f4" if self.enabled else DISABLED_FG
        c.create_text(
            cx, card_h * 0.80, text=subtitle,
            font=("DejaVu Sans", 13), fill=sub_color,
            width=(w - 12) * 0.82, justify="center",
        )


# ═════════════════════════════════════════════════════════════════════════════
# Fonctions utilitaires (inchangées)
# ═════════════════════════════════════════════════════════════════════════════
def setup_logging() -> None:
    os.makedirs(LOG_DIR, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        LOG_FILE, maxBytes=2_000_000, backupCount=3,
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





# ═════════════════════════════════════════════════════════════════════════════
# Fenêtre principale
# ═════════════════════════════════════════════════════════════════════════════
class KioskMenu:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Sélecteur de bornes")
        self.root.configure(bg=BG_COLOR)
        self.root.attributes("-fullscreen", True)

        for seq in ("<F11>", "<Escape>", "<Alt-F4>", "<Control-q>"):
            self.root.bind(seq, lambda _e: "break")

        self.apps_state = load_apps_state()
        self.tiles: dict[str, AppTile] = {}
        self._clock_var = tk.StringVar()
        self.build_ui()
        self._tick_clock()

    # ── Construction de l'interface ──────────────────────────────────────
    def build_ui(self) -> None:
        for widget in self.root.winfo_children():
            widget.destroy()

        # Bande de couleur en haut : unifie visuellement les 4 services,
        # apporte de la couleur dès le premier regard sur l'écran.
        stripe = tk.Canvas(self.root, height=8, bg=BG_COLOR, highlightthickness=0)
        stripe.pack(fill="x", side="top")
        self.root.update_idletasks()

        def draw_stripe(_e=None):
            stripe.delete("all")
            width = stripe.winfo_width() or self.root.winfo_screenwidth()
            n = len(APPS)
            seg = width / n
            for i, app in enumerate(APPS):
                stripe.create_rectangle(i * seg, 0, (i + 1) * seg + 1, 8,
                                        fill=app["color"], outline="")
        stripe.bind("<Configure>", draw_stripe)
        draw_stripe()

        # En-tête : présentation de la borne + horloge (garde le repère "l'écran
        # est vivant") à la place d'une salutation personnelle.
        header = tk.Frame(self.root, bg=BG_COLOR)
        header.pack(fill="x", pady=(24, 6))

        top_row = tk.Frame(header, bg=BG_COLOR)
        top_row.pack(fill="x", padx=50)

        tk.Label(
            top_row, text="Borne Multiservices", font=("DejaVu Sans", 30, "bold"),
            bg=BG_COLOR, fg=HEADER_FG,
        ).pack(side="left")

        clock_lbl = tk.Label(
            top_row, textvariable=self._clock_var, font=("DejaVu Sans", 20),
            bg=BG_COLOR, fg=MUTED_FG,
        )
        clock_lbl.pack(side="right")

        tk.Label(
            header,
            text=(
                "Clonez, effacez, virtualisez ou scannez vos disques et clés "
                "USB en toute sécurité, directement depuis cet écran."
            ),
            font=("DejaVu Sans", 15), bg=BG_COLOR, fg=MUTED_FG,
            wraplength=1100, justify="left",
        ).pack(anchor="w", padx=50, pady=(6, 0))

        tk.Label(
            header, text="Touchez une carte pour commencer",
            font=("DejaVu Sans", 12, "italic"), bg=BG_COLOR, fg="#586069",
        ).pack(anchor="w", padx=50, pady=(6, 0))

        # Grille des 4 services
        grid = tk.Frame(self.root, bg=BG_COLOR)
        grid.pack(expand=True, fill="both", padx=50, pady=14)

        for idx, app in enumerate(APPS):
            row, col = divmod(idx, 2)
            grid.rowconfigure(row, weight=1)
            grid.columnconfigure(col, weight=1)
            self.build_tile(grid, app, row, col)

        # Pied de page
        footer = tk.Frame(self.root, bg=BG_COLOR)
        footer.pack(fill="x", pady=(0, 16))

        tk.Frame(footer, bg="#21262d", height=1).pack(fill="x", padx=50, pady=(0, 10))

        bottom_row = tk.Frame(footer, bg=BG_COLOR)
        bottom_row.pack(fill="x", padx=50)

        tk.Label(
            bottom_row, text="Borne Multiservices", font=("DejaVu Sans", 10),
            bg=BG_COLOR, fg="#484f58",
        ).pack(side="left")

        admin_btn = tk.Button(
            bottom_row,
            text="⚙  Administration",
            font=("DejaVu Sans", 12),
            command=lambda: open_admin_panel(self.root, self.refresh_tiles),
            bg="#161b22",
            fg=MUTED_FG,
            activebackground="#21262d",
            activeforeground=HEADER_FG,
            relief="flat",
            padx=15,
            pady=8,
            bd=0,
            cursor="hand2",
        )
        admin_btn.pack(side="right")

    def build_tile(self, grid: tk.Frame, app: dict, row: int, col: int) -> None:
        enabled = self.apps_state.get(app["id"], True)
        tile = AppTile(grid, app, enabled, self.launch)
        tile.grid(row=row, column=col, sticky="nsew", padx=20, pady=20)
        self.tiles[app["id"]] = tile

    def refresh_tiles(self) -> None:
        self.apps_state = load_apps_state()
        self.build_ui()

    def _tick_clock(self) -> None:
        self._clock_var.set(time.strftime("%H:%M"))
        self.root.after(1000, self._tick_clock)

    # ── Lancement d'une application ──────────────────────────────────────
    def launch(self, app: dict) -> None:
        if not self.apps_state.get(app["id"], True):
            return

        logging.info("Lancement demandé : %s", app["id"])
        self.root.withdraw()
        try:
            result = subprocess.run(app["command"])
            logging.info(
                "Application %s terminée (code %s)", app["id"], result.returncode,
            )
        except FileNotFoundError:
            logging.error("Binaire introuvable pour %s : %s", app["id"], app["command"])
            messagebox.showerror(
                "Erreur", f"Impossible de lancer {app['title']} : binaire introuvable.",
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