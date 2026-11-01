"""Regenerates the small site images from the game art (needs Pillow).

    python website/tools/make-thumbs.py

The originals are 1-3 MB each; the site banner needs 128px rank icons, 192px
portraits and 48px currency icons.
"""
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[2]
jobs = [
    (root / 'assets/cardgame/Ranks', root / 'website/assets/ranks', 128, lambda n: n[:2].isdigit()),
    (root / 'assets/pfps', root / 'website/assets/pfps', 192, lambda n: True),
    (root / 'assets/icons', root / 'website/assets/icons', 48, lambda n: n in ('glimmer.png', 'cyllats.png')),
]
for src, dst, size, keep in jobs:
    dst.mkdir(parents=True, exist_ok=True)
    for path in sorted(src.glob('*.png')):
        if not keep(path.name):
            continue
        # Same filename the game stores (pfp_id), so a portrait id maps straight to a file.
        if path.name.startswith('pfp_') and 'icons' in str(src):
            continue
        with Image.open(path) as image:
            image = image.convert('RGBA')
            image.thumbnail((size, size), Image.LANCZOS)
            image.save(dst / path.name, optimize=True)
            print(dst.name, path.name, image.size)
