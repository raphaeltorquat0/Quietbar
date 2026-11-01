#!/usr/bin/env python3
"""Recorta o hero, gera os WebP (qualidade 85) e escreve manifest.json. Uso: site_captures.py <pasta>."""
import io
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageCms

OUT = Path(sys.argv[1])
# 4:3 com folga abaixo do painel, que tem 1188 px de altura contados do topo.
CROP = (2880 - 1680, 0, 2880, 1260)
CROP_SIZE = (1600, 1200)

DESCRIPTIONS = {
    "hero": ("Open panel, Ambient mode, ambient level 10 of 20, Focus on voice on, battery 72%, simulated WH-1000XM5",
             "The Quietbar panel open under its menu bar icon on a plain {theme} desktop, in Ambient mode with Focus on voice on, showing a WH-1000XM5 at 72% battery"),
    "hero-crop": ("Same as hero, cropped to the menu bar and the panel, scaled from 1680x1260",
                  "Close-up of the Quietbar panel under its menu bar icon in {theme} mode, in Ambient mode with Focus on voice on, showing a WH-1000XM5 at 72% battery"),
    "feature-sound": ("Sound mode tiles with Noise cancelling selected, transparent background",
                      "Three Quietbar sound mode tiles in {theme} mode: Noise cancelling selected, Ambient and Off"),
    "feature-eq": ("Equalizer settings tab with the Custom preset and a custom curve",
                   "Quietbar equalizer settings in {theme} mode with the Custom preset selected and a custom curve across Clear Bass and five bands"),
    "feature-battery": ("Connection popup with the 3D model, battery 72%, Noise cancelling",
                        "The Quietbar connection popup in {theme} mode with a 3D model of the headphones, the name WH-1000XM5, 72% battery and Noise cancelling"),
}

SRGB = ImageCms.createProfile("sRGB")


def to_srgb(path):
    """A captura vem com o perfil da tela: o nome do monitor não pode sair, e o WebP não leva perfil."""
    with Image.open(path) as image:
        icc = image.info.get("icc_profile") # sem ele o PNG já está em sRGB (chunk sRGB do recorte em Swift)
        if icc is None:
            return
        source = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        image = image.convert("RGBA")
    r, g, b, a = image.split()
    rgb = ImageCms.profileToProfile(Image.merge("RGB", (r, g, b)), source, SRGB)
    out = Image.merge("RGBA", (*rgb.split(), a))
    out.save(path, optimize=True, icc_profile=ImageCms.ImageCmsProfile(SRGB).tobytes())


for path in sorted(p for p in OUT.glob("*@2x.png") if not p.name.startswith("hero-crop")):
    to_srgb(path)

for theme in ("light", "dark"):
    with Image.open(OUT / f"hero-{theme}@2x.png") as hero:
        crop = hero.convert("RGB").crop(CROP).resize(CROP_SIZE, Image.LANCZOS)
    crop.save(OUT / f"hero-crop-{theme}@2x.png", optimize=True, icc_profile=ImageCms.ImageCmsProfile(SRGB).tobytes())

entries = []
for name, (state, alt) in DESCRIPTIONS.items():
    for theme in ("light", "dark"):
        png = OUT / f"{name}-{theme}@2x.png"
        webp = png.with_suffix(".webp")
        subprocess.run(["cwebp", "-quiet", "-q", "85", "-metadata", "none", str(png), "-o", str(webp)], check=True)
        with Image.open(png) as image:
            width, height = image.size
        for file in (png, webp):
            entries.append({"file": file.name, "width": width, "height": height, "theme": theme, "state": state, "alt": alt.format(theme=theme)})

(OUT / "manifest.json").write_text(json.dumps(entries, indent=2) + "\n")
print(f"{len(entries)} arquivos")
