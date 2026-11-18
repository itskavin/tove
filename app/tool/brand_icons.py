#!/usr/bin/env python3
"""Generate every Tove icon from the two brand sources in assets/brand/.

    uv run --with pillow --with numpy python3 tool/brand_icons.py      (from app/)

Sources (the user's own logo, 16 Nov 2026):
- tove-logo-source.png: the original artwork, a soft white three-lobed mark on black.
- tove-mark.svg: its silhouette, traced with potrace (absolute M/L/C/Z path in a 1000 box).

Two renderings of the mark:
- soft: the artwork's own shading (its gradients fade into the black) as alpha, with crisp edges from the
  vector outline, so it stays sharp when scaled up (iOS 1024 px, macOS 1024 px);
- mono: the flat silhouette (white) for notification, monochrome/themed and in-app marks.

Writes the Android adaptive/legacy/monochrome launcher icons, the notification icon, the splash badge,
iOS AppIcon and launch image, the CallKit template, macOS and Windows icons, a Linux window icon,
the web favicon, manifest and maskable icons, the transparent masters in assets/brand/ and the Dart path
used by the in-app BrandMark. A contact sheet goes to build/brand_icons_preview.png.
"""
import json
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

APP = Path(__file__).resolve().parent.parent
BRAND = APP / "assets" / "brand"
RES = APP / "android" / "app" / "src" / "main" / "res"
TINT = (249, 240, 234)          # the artwork's warm white
BLACK = (0, 0, 0)

SVG = (BRAND / "tove-mark.svg").read_text()
PATH_D = re.search(r' d="([^"]+)"', SVG).group(1)
SRC_BOX = [float(v) for v in re.search(r'data-source-box="([^"]+)"', SVG).group(1).split()]


# --- path ---------------------------------------------------------------------------------------------------
def commands(d):
    """[(cmd, [floats])] for an absolute M/L/C/Z path."""
    out = []
    for cmd, args in re.findall(r"([MLCZ])([^MLCZ]*)", d):
        out.append((cmd, [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?", args)]))
    return out


CMDS = commands(PATH_D)


def polygons(n=20):
    """The path flattened into polygons, in the 1000 box."""
    polys, cur, last = [], [], (0.0, 0.0)
    for cmd, a in CMDS:
        if cmd == "M":
            if cur:
                polys.append(cur)
            cur, last = [(a[0], a[1])], (a[0], a[1])
        elif cmd == "L":
            for i in range(0, len(a), 2):
                last = (a[i], a[i + 1])
                cur.append(last)
        elif cmd == "C":
            for i in range(0, len(a), 6):
                p1, p2, e = (a[i], a[i + 1]), (a[i + 2], a[i + 3]), (a[i + 4], a[i + 5])
                for k in range(1, n + 1):
                    t = k / n
                    u = 1 - t
                    cur.append((u ** 3 * last[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * e[0],
                                u ** 3 * last[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * e[1]))
                last = e
        elif cmd == "Z" and cur:
            polys.append(cur)
            cur = []
    if cur:
        polys.append(cur)
    return polys


POLYS = polygons()
ALL = np.array([p for poly in POLYS for p in poly])
MARK_Y0, MARK_Y1 = ALL[:, 1].min(), ALL[:, 1].max()


def coverage(side, ss=4):
    """Anti-aliased silhouette coverage (0..1) of the 1000 box drawn at side × side."""
    big = Image.new("L", (side * ss, side * ss), 0)
    draw = ImageDraw.Draw(big)
    k = side * ss / 1000
    for poly in POLYS:
        draw.polygon([(x * k, y * k) for x, y in poly], fill=255)
    return np.asarray(big.resize((side, side), Image.BOX)).astype(float) / 255


# Optical centre: a triangle's mass sits low, so shift the mark up by half its centroid's offset.
_c = coverage(500)
_cy = (np.arange(500)[:, None] * _c).sum() / _c.sum() * 2
DY = -(_cy - (MARK_Y0 + MARK_Y1) / 2) / 2           # in 1000-box units
CENTRE_Y = (MARK_Y0 + MARK_Y1) / 2 - DY            # the box point that goes to the canvas centre

# --- the soft artwork as alpha ------------------------------------------------------------------------------
_src = np.asarray(Image.open(BRAND / "tove-logo-source.png").convert("RGB")).astype(float)
_bg = np.array([0, 0, 4.0])
SRC_ALPHA = np.clip((np.clip(_src - _bg, 0, None) / (np.array(TINT) - _bg)).max(axis=2), 0, 1)


def soft_alpha(side):
    """The artwork's alpha for the 1000 box drawn at side × side, with the outline's crisp edges."""
    x0, y0, x1, y1 = SRC_BOX
    k = side / 1000
    # The traced bounds span x 0..1000 and y MARK_Y0..MARK_Y1 of the box.
    w, h = max(1, round(1000 * k)), max(1, round((MARK_Y1 - MARK_Y0) * k))
    crop = Image.fromarray((SRC_ALPHA * 255).astype(np.uint8)).crop((round(x0), round(y0), round(x1), round(y1)))
    art = crop.resize((w, h), Image.LANCZOS)
    radius = max(1, round(side / 220)) * 2 + 1
    art = art.filter(ImageFilter.MaxFilter(radius))      # push the shading out under the vector edge
    full = Image.new("L", (side, side), 0)
    full.paste(art, (0, round(MARK_Y0 * k)))
    return np.asarray(full).astype(float) / 255 * coverage(side)


def mark(side, mode):
    """RGBA side × side: the 1000 box (mark centred optically) as soft artwork or flat white."""
    a = soft_alpha(side) if mode == "soft" else coverage(side)
    rgb = TINT if mode == "soft" else (255, 255, 255)
    img = np.zeros((side, side, 4), np.uint8)
    img[..., :3] = rgb
    img[..., 3] = np.clip(a * 255 + 0.5, 0, 255).astype(np.uint8)
    out = Image.fromarray(img, "RGBA")
    # Move the optical centre to the middle.
    shift = round((500 - CENTRE_Y) * side / 1000)
    return out.transform(out.size, Image.AFFINE, (1, 0, 0, 0, 1, -shift), resample=Image.BICUBIC)


def icon(size, frac, mode="soft", bg=BLACK, shape="square", radius=0.0, inset=0.0, opaque=False):
    """A size × size icon: a background shape and the mark at frac of the canvas width.

    Drawn at 4× then reduced, so small sizes stay crisp."""
    ss = 4 if size <= 256 else 2
    S = size * ss
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0) if not opaque else BLACK + (255,))
    if bg is not None:
        d = ImageDraw.Draw(canvas)
        i = round(inset * S)
        box = (i, i, S - 1 - i, S - 1 - i)
        if shape == "circle":
            d.ellipse(box, fill=bg + (255,))
        elif shape == "round":
            d.rounded_rectangle(box, radius=round(radius * S), fill=bg + (255,))
        else:
            d.rectangle(box, fill=bg + (255,))
    side = round(frac * S)
    m = mark(side, mode)
    canvas.alpha_composite(m, ((S - side) // 2, (S - side) // 2))
    out = canvas.resize((size, size), Image.LANCZOS)
    return out.convert("RGB") if opaque else out


def save(img, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)
    return path


# --- vector outputs -----------------------------------------------------------------------------------------
def vector_group(viewport, mark_width, colour="#FFFFFFFF"):
    """A VectorDrawable <group> drawing the mark mark_width wide, centred optically in viewport."""
    s = mark_width / 1000
    tx = (viewport - mark_width) / 2
    ty = viewport / 2 - CENTRE_Y * s
    return (f'    <group android:scaleX="{s:.5f}" android:scaleY="{s:.5f}"\n'
            f'        android:translateX="{tx:.3f}" android:translateY="{ty:.3f}">\n'
            f'        <path android:fillColor="{colour}"\n'
            f'            android:pathData="{PATH_D}" />\n'
            f'    </group>\n')


def vector(dp, viewport, mark_width, comment):
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            f'<!-- {comment} Generated by tool/brand_icons.py from assets/brand/tove-mark.svg. -->\n'
            '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            f'    android:width="{dp}dp"\n    android:height="{dp}dp"\n'
            f'    android:viewportWidth="{viewport}"\n    android:viewportHeight="{viewport}">\n'
            + vector_group(viewport, mark_width) + '</vector>\n')


def dart_path():
    lines = []
    f = lambda v: ("%.1f" % v)
    for cmd, a in CMDS:
        if cmd == "M":
            lines.append(f"    ..moveTo({f(a[0])}, {f(a[1])})")
        elif cmd == "L":
            for i in range(0, len(a), 2):
                lines.append(f"    ..lineTo({f(a[i])}, {f(a[i + 1])})")
        elif cmd == "C":
            for i in range(0, len(a), 6):
                lines.append("    ..cubicTo(" + ", ".join(f(v) for v in a[i:i + 6]) + ")")
        elif cmd == "Z":
            lines.append("    ..close()")
    return f"""// GENERATED by tool/brand_icons.py from assets/brand/tove-mark.svg. Do not edit.
// ignore_for_file: lines_longer_than_80_chars

import 'dart:ui';

/// The Tove mark's silhouette in a 1000 × 1000 box.
const double toveMarkBox = 1000;

/// The mark's vertical centre in the box, optically adjusted (a triangle's
/// mass sits low).
const double toveMarkCentreY = {CENTRE_Y:.1f};

/// The mark's outline, built once.
final Path toveMarkPath = Path()
{chr(10).join(lines)};
"""


# --- write ---------------------------------------------------------------------------------------------------
def main():
    written = []
    w = lambda p: written.append(p.relative_to(APP))

    # Masters.
    w(save(mark(1024, "soft"), BRAND / "tove-mark-soft.png"))
    w(save(mark(1024, "mono"), BRAND / "tove-mark-mono.png"))

    # Android launcher: adaptive (108 dp, mark 46 dp inside the 66 dp safe zone) + legacy 48 dp.
    dens = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, k in dens.items():
        w(save(icon(round(108 * k), 46 / 108, bg=None), RES / f"mipmap-{name}" / "ic_launcher_foreground.png"))
        w(save(icon(round(48 * k), 0.56, shape="round", radius=0.2, inset=1 / 48), RES / f"mipmap-{name}" / "ic_launcher.png"))
        w(save(icon(round(112 * k), 0.56, shape="circle"), RES / f"drawable-{name}" / "splash_badge.png"))
    adaptive = ('<?xml version="1.0" encoding="utf-8"?>\n'
                '<!-- Generated by tool/brand_icons.py: the Tove mark on black, with a themed (monochrome) layer. -->\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@color/ic_launcher_background" />\n'
                '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
                '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
                '</adaptive-icon>\n')
    p = RES / "mipmap-anydpi-v26" / "ic_launcher.xml"
    p.parent.mkdir(exist_ok=True)
    p.write_text(adaptive)
    w(p)
    p = RES / "drawable" / "ic_launcher_monochrome.xml"
    p.write_text(vector(108, 108, 46, "Themed-icon layer: the Tove mark, flat, inside the 66 dp safe zone."))
    w(p)
    p = RES / "drawable" / "ic_stat_hermes.xml"
    p.write_text(vector(24, 24, 22, "Status-bar icon: the Tove mark as a white silhouette (Android tints it)."
                                    " The name is kept for the code that references it."))
    w(p)

    # iOS.
    ios = APP / "ios" / "Runner" / "Assets.xcassets"
    contents = json.loads((ios / "AppIcon.appiconset" / "Contents.json").read_text())
    done = set()
    for im in contents["images"]:
        fn = im.get("filename")
        if not fn or fn in done:
            continue
        done.add(fn)
        px = round(float(im["size"].split("x")[0]) * float(im["scale"].rstrip("x")))
        w(save(icon(px, 0.56, opaque=True), ios / "AppIcon.appiconset" / fn))
    for fn, k in (("LaunchImage.png", 1), ("LaunchImage@2x.png", 2), ("LaunchImage@3x.png", 3)):
        w(save(icon(112 * k, 0.56, shape="circle"), ios / "LaunchImage.imageset" / fn))
    callkit = ios / "CallKitIcon.imageset" / "callkit-hermes.svg"
    callkit.write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="-60 -60 1120 1120" width="40" height="40">'
                       f'<path fill="#000000" transform="translate(0 {500 - CENTRE_Y:.1f})" d="{PATH_D}"/></svg>\n')
    w(callkit)

    # macOS: the Big Sur grid (824 px rounded square in 1024).
    mac = APP / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for px in (16, 32, 64, 128, 256, 512, 1024):
        w(save(icon(px, 0.46, shape="round", radius=0.181, inset=100 / 1024), mac / f"app_icon_{px}.png"))

    # Windows .ico.
    ico = APP / "windows" / "runner" / "resources" / "app_icon.ico"
    big = icon(256, 0.58, shape="round", radius=0.2, inset=0.02)
    big.save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    w(ico)

    # Linux window icon (bundled as a Flutter asset; my_application.cc loads it).
    w(save(icon(256, 0.58, shape="round", radius=0.2, inset=0.02), BRAND / "tove-icon-256.png"))

    # Web.
    web = APP / "web"
    w(save(icon(32, 0.66, shape="round", radius=0.22), web / "favicon.png"))
    for px in (192, 512):
        w(save(icon(px, 0.56, shape="round", radius=0.22), web / "icons" / f"Icon-{px}.png"))
        w(save(icon(px, 0.46), web / "icons" / f"Icon-maskable-{px}.png"))       # inside the 80 % safe circle
    w(save(icon(180, 0.56, opaque=True), web / "icons" / "apple-touch-icon.png"))

    # Dart.
    p = APP / "lib" / "src" / "ui" / "common" / "tove_mark_path.dart"
    p.write_text(dart_path())
    w(p)

    # Contact sheet: the launcher icon at 48 and 192 px, notification glyph, maskable crop, on light and dark.
    sheet = Image.new("RGB", (900, 300), (247, 246, 243))
    ImageDraw.Draw(sheet).rectangle((450, 0, 900, 300), fill=(18, 18, 19))
    for x0 in (0, 450):
        sheet.paste(icon(48, 0.56, shape="round", radius=0.2), (x0 + 20, 20), icon(48, 0.56, shape="round", radius=0.2))
        i192 = icon(192, 0.56, shape="round", radius=0.22)
        sheet.paste(i192, (x0 + 90, 20), i192)
        adaptive_preview = Image.new("RGBA", (192, 192), (0, 0, 0, 0))
        circle = Image.new("L", (192, 192), 0)
        ImageDraw.Draw(circle).ellipse((0, 0, 191, 191), fill=255)
        fg = icon(288, 46 / 108, bg=None).crop((48, 48, 240, 240))          # what a circle mask shows (72 of 108 dp)
        adaptive_preview.paste(Image.new("RGBA", (192, 192), BLACK + (255,)), (0, 0), circle)
        adaptive_preview.alpha_composite(Image.composite(fg, Image.new("RGBA", (192, 192)), circle))
        sheet.paste(adaptive_preview, (x0 + 290, 20), adaptive_preview)
        glyph = mark(24, "mono")
        tint = Image.new("RGBA", glyph.size, (90, 90, 90, 255) if x0 == 0 else (230, 230, 230, 255))
        sheet.paste(tint, (x0 + 30, 240), glyph)
        g96 = mark(96, "mono")
        sheet.paste(Image.new("RGBA", g96.size, (90, 90, 90, 255) if x0 == 0 else (230, 230, 230, 255)), (x0 + 90, 200), g96)
    (APP / "build").mkdir(exist_ok=True)
    sheet.save(APP / "build" / "brand_icons_preview.png")

    print(f"optical shift {DY:+.1f}/1000, centre y {CENTRE_Y:.1f}")
    for p in written:
        print(p)


if __name__ == "__main__":
    sys.exit(main())
