#!/usr/bin/env python3
"""Affiche measure.json : échelle d'affichage de chaque capture (taille affichée / largeur native du PNG source)."""
import glob, json, os, sys
from PIL import Image

web, report = sys.argv[1], json.load(open(sys.argv[2]))
nat = {os.path.basename(f)[:-4]: Image.open(f).width for f in glob.glob(f"{web}/src/assets/shots/*.png")}
bad = 0
for w, r in report.items():
    print(f"{w} px — première capture à y={r['heroTop']}")
    for i in r["images"]:
        n = i["src"].split(".")[0]
        s = i["shown"] / nat.get(n, i["shown"])
        flag = "" if s >= 0.495 else "  < 50 %"
        bad += bool(flag)
        print(f"   {n:18} y={i['top']:5}  {i['shown']:4}/{nat.get(n)} px  {s:4.0%}{flag}")
sys.exit(1 if bad else 0)
