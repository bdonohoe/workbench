#!/usr/bin/env python3
"""App Store screenshots and creative assets for the Bench iPhone app.

Captures come from the demo mode in the simulator (see capture.sh), so
nothing here shows a real project. Run from the repo root:

    scripts/listing-screenshots/capture.sh
    python3 scripts/listing-screenshots/compose.py

Writes fastlane/screenshots/en-US (6.9", 6.3", iPhone Duo and iPad 13" sets) and
fastlane/creative-assets (universal header/search asset with crop previews).
"""
import os
import subprocess
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.expanduser("~/.claude/skills/app-store-assets/scripts"))
import storefront_kit as kit  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
RAW = os.path.join(ROOT, "fastlane/screenshots/raw")
OUT = os.path.join(ROOT, "fastlane/screenshots/en-US")
CREATIVE = os.path.join(ROOT, "fastlane/creative-assets")
CACHE = os.path.join(ROOT, "build/listing")

# Bench's own colors: the icon's graphite, the phone's cool paper and
# cream ink, and the working orange as the one warm thing.
GRAPHITE = (33, 36, 46)
PAPER = (241, 242, 244)
CREAM = (244, 241, 234)
INK = (27, 26, 24)
ORANGE = (217, 120, 87)
GRID_DARK = (52, 56, 70)
GRID_LIGHT = (226, 228, 233)

MONO = "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/SF-Mono-Semibold.otf"
ICON = os.path.join(ROOT, "bench-icon.icon/Assets")


def svg(name, height, colour=None):
    """One of the icon's SVG layers, rendered at a height and cropped to its ink."""
    os.makedirs(CACHE, exist_ok=True)
    out = os.path.join(CACHE, f"{name}-{height}.png")
    subprocess.run(["rsvg-convert", "-h", str(height * 3), "-o", out, os.path.join(ICON, f"{name}.svg")], check=True)
    im = Image.open(out).convert("RGBA")
    im = im.crop(im.getbbox())
    im = im.resize((round(im.size[0] * height / im.size[1]), height), Image.LANCZOS)
    if colour:
        solid = Image.new("RGBA", im.size, colour + (255,))
        solid.putalpha(im.split()[3])
        im = solid
    return im


def prompt(img, lines, x, y, size, ink, max_width):
    """The headline as a terminal prompt: the icon's chevron, the words in
    SF Mono, and the icon's orange spark where the cursor would be."""
    d = ImageDraw.Draw(img)
    chevron_w = round(size * 0.62)
    f, size = kit.fit_text(d, lines, MONO, size, max_width - chevron_w - size)
    chevron = svg("prompt", round(size * 0.78), ink)
    img.alpha_composite(chevron, (x, y + round(size * 0.24)))
    tx = x + chevron.size[0] + round(size * 0.45)
    leading = round(size * 1.22)
    for i, line in enumerate(lines):
        d.text((tx, y + i * leading), line, font=f, fill=ink)
    last = lines[-1]
    spark = svg("glyph", round(size * 0.8))
    sx = tx + round(d.textlength(last, font=f)) + round(size * 0.3)
    img.alpha_composite(spark, (sx, y + (len(lines) - 1) * leading + round(size * 0.2)))
    return y + len(lines) * leading


# Each screenshot: capture, background, headline, where the device sits,
# and one piece of UI lifted out of the capture (box in capture pixels),
# set over the spot it came from so it reads as lifted, not repeated.
SHOTS = [
    dict(name="01-sessions", shot="list.png", dark=True, lines=["Every session,", "at a glance"],
         device_y=760, chip=dict(box=(40, 1185, 1280, 1468), y=1735, rot=-2.5, radius=60)),
    dict(name="02-allow", shot="permission-dark.png", dark=False, lines=["Allow it from", "anywhere"],
         device_y=700, chip=dict(box=(28, 2290, 1292, 2580), y=2540, rot=2, radius=56)),
    dict(name="03-checklist", shot="working.png", dark=True, lines=["Follow along", "as Claude works"],
         device_y=700, chip=dict(box=(30, 1836, 1290, 2520), y=2150, rot=-2, radius=48)),
    dict(name="04-diff", shot="diff-agent.png", dark=False, lines=["Review every", "change"],
         device_y=760, chip=dict(box=(0, 530, 1250, 920), y=1200, rot=2, radius=36)),
    dict(name="05-agents", shot="agent.png", dark=True, lines=["Agents on their", "own branches"],
         device_y=760, chip=dict(shot="list.png", box=(96, 815, 1278, 1168), y=1900, rot=-2, radius=56)),
    dict(name="06-mac", shot="list-dark.png", dark=False, lines=["Straight from", "your Mac"],
         device_y=760, chip=None),
]

DEVICE_W = 1180


def screenshot(spec):
    bg, ink, grid = (GRAPHITE, CREAM, GRID_DARK) if spec["dark"] else (PAPER, INK, GRID_LIGHT)
    img = kit.canvas(kit.IPHONE_69, bg)
    kit.grid(img, grid, cell=66, alpha=255, width=2)
    prompt(img, spec["lines"], 92, 230, 104, ink, kit.IPHONE_69[0] - 184)
    x = (kit.IPHONE_69[0] - DEVICE_W) // 2
    kit.device(img, os.path.join(RAW, spec["shot"]), kit.IPHONE_17_PRO_MAX, DEVICE_W, (x, spec["device_y"]))
    c = spec["chip"]
    if c:
        scale = c.get("scale", 1.0)
        w = round((c["box"][2] - c["box"][0]) * scale)
        kit.chip(img, os.path.join(RAW, c.get("shot", spec["shot"])), c["box"],
                 ((kit.IPHONE_69[0] - w) // 2, c["y"]), scale=scale, rot=c["rot"], radius=c["radius"])
    return img


# iPhone Duo, inner display, open flat in landscape. Same story and chips,
# with boxes in the Duo captures' pixels. There is no Duo bezel in Apple's
# frames, so the device is a plain rounded one.
DUO = (2853, 2007)
RAW_DUO = os.path.join(ROOT, "fastlane/screenshots/raw-duo")
DUO_CHIPS = {
    "01-sessions": dict(box=(40, 872, 2560, 1100), rot=-1.5, radius=70),
    "02-allow": dict(box=(33, 1430, 2568, 1724), rot=1.2, radius=70),
    "03-checklist": dict(box=(33, 980, 2568, 1655), rot=-1.2, radius=60),
    "04-diff": dict(box=(0, 330, 1880, 895), rot=1.2, radius=40),
    "05-agents": dict(shot="list.png", box=(90, 498, 2560, 852), rot=-1.2, radius=70),
}


def duo_device(img, shot_path, width, pos):
    shot = Image.open(shot_path).convert("RGBA")
    scale = width / shot.size[0]
    shot = shot.resize((width, round(shot.size[1] * scale)), Image.LANCZOS)
    bezel, radius = 34, 110
    body = Image.new("RGBA", (shot.size[0] + 2 * bezel, shot.size[1] + 2 * bezel), (0, 0, 0, 0))
    d = ImageDraw.Draw(body)
    d.rounded_rectangle([0, 0, body.size[0] - 1, body.size[1] - 1], radius=radius + bezel, fill=(14, 15, 18, 255))
    d.rounded_rectangle([3, 3, body.size[0] - 4, body.size[1] - 4], radius=radius + bezel - 3, outline=(70, 72, 80, 255), width=3)
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.size[0] - 1, shot.size[1] - 1], radius=radius, fill=255)
    body.paste(shot, (bezel, bezel), mask)
    kit.place(img, body, pos)
    return scale, bezel


def duo_screenshot(spec):
    bg, ink, grid = (GRAPHITE, CREAM, GRID_DARK) if spec["dark"] else (PAPER, INK, GRID_LIGHT)
    img = kit.canvas(DUO, bg)
    kit.grid(img, grid, cell=80, alpha=255, width=2)
    prompt(img, [" ".join(spec["lines"])], 150, 150, 120, ink, DUO[0] - 300)
    width = 2420
    x, y = (DUO[0] - width) // 2 - 34, 420
    scale, bezel = duo_device(img, os.path.join(RAW_DUO, spec["shot"]), width, (x, y))
    c = DUO_CHIPS.get(spec["name"])
    if c:
        lift = scale * 1.12
        w = round((c["box"][2] - c["box"][0]) * lift)
        h = round((c["box"][3] - c["box"][1]) * lift)
        origin_y = y + bezel + c["box"][1] * scale + (c["box"][3] - c["box"][1]) * scale / 2
        cy = min(round(origin_y - h / 2), DUO[1] - h - 40)
        kit.chip(img, os.path.join(RAW_DUO, c.get("shot", spec["shot"])), c["box"],
                 ((DUO[0] - w) // 2, cy), scale=lift, rot=c["rot"], radius=c["radius"])
    return img


# iPad 13", portrait, from SIM="iPad Pro 13-inch (M5)" OUT=fastlane/screenshots/raw-ipad
# capture.sh. The sidebar sits beside the conversation, so the chips come
# from the detail pane. Boxes are in the iPad captures' pixels.
RAW_IPAD = os.path.join(ROOT, "fastlane/screenshots/raw-ipad")
IPAD_SHOTS = [
    dict(name="01-sessions", shot="list.png", dark=True, lines=["Every session,", "at a glance"],
         chip=dict(box=(32, 420, 688, 816), scale=1.9, y=1650, rot=-2.5, radius=70)),
    dict(name="02-allow", shot="permission-dark.png", dark=False, lines=["Allow it from", "anywhere"],
         chip=dict(box=(744, 2392, 2032, 2588), scale=1.25, y=2180, rot=2, radius=56)),
    dict(name="03-checklist", shot="working.png", dark=True, lines=["Follow along", "as Claude works"],
         chip=dict(box=(744, 2052, 2032, 2516), scale=1.25, y=2000, rot=-2, radius=48)),
    dict(name="04-diff", shot="diff-agent.png", dark=False, lines=["Review every", "change"],
         chip=dict(box=(720, 190, 2064, 610), scale=1.25, y=1150, rot=2, radius=36)),
    dict(name="05-agents", shot="agent.png", dark=True, lines=["Agents on their", "own branches"],
         chip=dict(box=(800, 1740, 2032, 1972), scale=1.4, y=1950, rot=-2, radius=48)),
]


def ipad_screenshot(spec):
    W, H = kit.IPAD_13
    bg, ink, grid = (GRAPHITE, CREAM, GRID_DARK) if spec["dark"] else (PAPER, INK, GRID_LIGHT)
    img = kit.canvas(kit.IPAD_13, bg)
    kit.grid(img, grid, cell=86, alpha=255, width=2)
    prompt(img, spec["lines"], 140, 200, 130, ink, W - 280)
    width = 1880
    kit.device(img, os.path.join(RAW_IPAD, spec["shot"]), kit.IPAD_PRO_13, width, ((W - width) // 2, 680),
               ipad_corner=True)
    c = spec["chip"]
    w = round((c["box"][2] - c["box"][0]) * c["scale"])
    kit.chip(img, os.path.join(RAW_IPAD, spec["shot"]), c["box"], ((W - w) // 2, c["y"]),
             scale=c["scale"], rot=c["rot"], radius=c["radius"])
    return img


def universal():
    """The header and search image from one file: what Bench is, with the
    sessions list and a permission prompt, all inside the shared safe box."""
    W, H = kit.UNIVERSAL_16x9
    img = kit.canvas((W, H), GRAPHITE)
    kit.grid(img, GRID_DARK, cell=110, alpha=255, width=3)
    sx, sy, sw, sh = kit.UNIVERSAL_SAFE
    prompt(img, ["Your sessions,", "in your pocket"], sx + 160, sy + 760, 200, CREAM, 2150)
    dw = 1300
    kit.device(img, os.path.join(RAW, "list.png"), kit.IPHONE_17_PRO_MAX, dw, (sx + sw - dw - 260, sy + 170))
    piece_w = round((1292 - 28) * 1.25)
    kit.chip(img, os.path.join(RAW, "permission-dark.png"), (28, 2290, 1292, 2580),
             (sx + sw - piece_w - 60, sy + 1500), scale=1.25, rot=-3, radius=70)
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    paths = []
    for spec in SHOTS:
        img = screenshot(spec)
        p69 = os.path.join(OUT, f"iphone69_{spec['name']}.png")
        kit.save(img, p69)
        kit.save(img.convert("RGB").resize((1206, 2622), Image.LANCZOS), os.path.join(OUT, f"iphone63_{spec['name']}.png"))
        paths.append(p69)
    kit.contact_sheet(paths, os.path.join(CACHE, "contact-sheet.png"), thumb_height=900, columns=6)
    duo_paths = []
    for spec in SHOTS:
        p = os.path.join(OUT, f"duo_{spec['name']}.png")
        kit.save(duo_screenshot(spec), p)
        duo_paths.append(p)
    kit.contact_sheet(duo_paths, os.path.join(CACHE, "contact-sheet-duo.png"), thumb_height=500, columns=3)
    ipad_paths = []
    for spec in IPAD_SHOTS:
        p = os.path.join(OUT, f"ipad13_{spec['name']}.png")
        kit.save(ipad_screenshot(spec), p)
        ipad_paths.append(p)
    kit.contact_sheet(ipad_paths, os.path.join(CACHE, "contact-sheet-ipad.png"), thumb_height=900, columns=5)
    os.makedirs(CREATIVE, exist_ok=True)
    kit.universal_crops(universal(), CREATIVE, stem="bench")


if __name__ == "__main__":
    main()
