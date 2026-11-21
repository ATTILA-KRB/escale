#!/usr/bin/env python3
"""Recadre les captures brutes de `--selftest-showcase` (2880×1800, Retina) en images du site.

Usage : crops.py <dossier raw> <web/>
Chaque recadrage est dimensionné pour être affiché à ≥ 50 % de sa taille (texte d'UI ≥ 11 px CSS) :
largeur ≈ 2 × largeur d'affichage prévue dans Landing.astro (800 px fonctions, 380/760 px tuiles, 350 px mobile).
"""
import sys
from pathlib import Path
from PIL import Image

raw, web = Path(sys.argv[1]), Path(sys.argv[2])
out = web / "src/assets/shots"
out.mkdir(parents=True, exist_ok=True)

# nom du site : (capture brute, boîte x1, y1, x2, y2 en pixels Retina) ; None = image entière
CROPS = {
    "hero": ("00-hero", None),
    "hero-mobile": ("01-hero", (580, 130, 1280, 1300)),
    "sftp": ("01-hero", (0, 0, 1520, 960)),
    "tunnels": ("05-tunnels", (700, 260, 2180, 1540)),
    "multiexec": ("03-multiexec", (0, 1264, 1500, 1680)),
    "tile-monitoring": ("01-hero", (580, 900, 2070, 990)),
    "tile-macros": ("13-macros", (0, 130, 590, 710)),
    "tile-quickconnect": ("10-accueil", (0, 140, 590, 720)),
    "tile-import": ("12-outils", (0, 725, 590, 1305)),
    "tile-colors": ("11-theme-dracula", (580, 980, 2070, 1690)),
    # Variantes servies sous 768 px (Shot `mobile`) : 700 px pour ~350 px CSS, 604 px pour les tuiles (~302 px CSS).
    "sftp-mobile": ("01-hero", (0, 130, 580, 1000)),
    "tunnels-mobile": ("05-tunnels", (800, 340, 1500, 1160)),
    "multiexec-mobile": ("03-multiexec", (0, 1264, 700, 1680)),
    "tile-monitoring-mobile": ("01-hero", (580, 900, 1184, 990)),
    "tile-panes": ("01-hero", (580, 130, 1250, 830)),
    "tile-panes-mobile": ("01-hero", (580, 130, 1184, 830)),
    "tile-colors-mobile": ("11-theme-dracula", (640, 980, 1244, 1690)),
    "tile-macros-mobile": ("13-macros", (0, 130, 590, 710)),
    "tile-quickconnect-mobile": ("10-accueil", (0, 140, 590, 720)),
    "tile-import-mobile": ("12-outils", (0, 725, 590, 1305)),
}

for name, (src, box) in CROPS.items():
    im = Image.open(raw / f"{src}.png").convert("RGB")
    if box:
        im = im.crop(box)
    im.save(out / f"{name}.png", optimize=True)
    print(f"{name:18} {im.width}×{im.height}")

# Image de partage 1200×630 : haut de la fenêtre du héros.
im = Image.open(raw / "00-hero.png").convert("RGB").crop((0, 0, 2560, 1344)).resize((1200, 630), Image.Resampling.LANCZOS)
im.save(web / "public/og.png", optimize=True)
print("og.png             1200×630")
