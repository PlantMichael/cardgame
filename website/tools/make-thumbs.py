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

# Large key art for the home page: JPEG, since photographic painting art is
# 5-10x smaller than PNG. (name in site, source, max width)
art = [
    ('hero', root / 'assets/wallapepr.png', 2000),
    ('sapiens', root / 'assets/green/tigershark.png', 1000),
    ('coven', root / 'assets/crimson/moonchild.png', 1000),
    ('junklings', root / 'assets/black/trashcolossus.png', 1000),
    ('gundari', root / 'assets/maps/thedunes.png', 1000),
    ('mokotai', root / 'assets/teal/frostyeti.png', 1000),
]
dst = root / 'website/assets/art'
dst.mkdir(parents=True, exist_ok=True)
for name, src, width in art:
    with Image.open(src) as image:
        image = image.convert('RGB')
        image.thumbnail((width, width * 2), Image.LANCZOS)
        image.save(dst / f'{name}.jpg', quality=80, optimize=True, progressive=True)
        print('art', name, image.size, (dst / f'{name}.jpg').stat().st_size // 1024, 'KB')
