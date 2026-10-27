#!/usr/bin/env python3
"""Build the README / AltStore showcase images from raw simulator captures.

Usage:
    .venv/bin/python scripts/make_mockups.py <captures-dir> [out-dir]

<captures-dir> holds full-size iPhone 17 simulator screenshots (1206x2622),
named after the slides below (dashboard.png, rides.png, ...). Take them with
`xcrun simctl io <udid> screenshot <file>` after
`xcrun simctl status_bar <udid> override --time 09:41 ...`.
Output goes to docs/screenshots by default. Needs Pillow.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FONT = "/System/Library/Fonts/SFNS.ttf"

W, H = 1290, 2400          # slide size (App Store 6.7" friendly ratio)
MARGIN = 90
SCREEN_W = 1000            # rendered width of the phone screen
BEZEL = 20
RADIUS = 150               # outer corner radius of the device

# name, headline, subtitle, accent colour
SLIDES = [
    ("dashboard", "Live dashboard", "Speed, power, gear, light, cruise and lock", (10, 132, 255)),
    ("rides", "Every ride, recorded", "Found automatically, with weekly totals", (64, 156, 255)),
    ("map", "Your route, by speed", "The GPS track coloured from slow to fast", (255, 159, 10)),
    ("ride-detail", "Ride details", "Tiles and foldable charts, regen included", (218, 70, 239)),
    ("battery", "Every charge", "Distance and energy from charge to charge", (48, 209, 88)),
    ("health", "Battery health", "Efficiency, pack capacity and resistance", (52, 199, 140)),
    ("alerts", "Your own alerts", "Coloured warnings for battery and heat", (255, 204, 0)),
    ("backup", "Backup and restore", "Your rides kept safe in iCloud Drive", (90, 200, 250)),
]


def font(size, weight="Regular"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def fitted_font(text, size, weight, max_w):
    while size > 20:
        f = font(size, weight)
        if f.getlength(text) <= max_w:
            return f
        size -= 2
    return font(size, weight)


def background(w, h, accent, glow_center):
    """Near-black vertical gradient with a soft accent glow."""
    base = Image.new("RGB", (w, h))
    px = ImageDraw.Draw(base)
    top, bottom = (14, 16, 22), (4, 5, 8)
    for y in range(h):
        t = y / (h - 1)
        px.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    glow = Image.new("L", (w, h), 0)
    gx, gy, r = glow_center
    ImageDraw.Draw(glow).ellipse([gx - r, gy - r, gx + r, gy + r], fill=150)
    glow = glow.filter(ImageFilter.GaussianBlur(r * 0.55))
    color = Image.new("RGB", (w, h), accent)
    return Image.composite(color, base, glow.point(lambda v: int(v * 0.55)))


def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius, fill=255)
    return m


def device(screen, screen_w=SCREEN_W):
    """Screenshot inside a slim titanium-look frame with a Dynamic Island."""
    s = screen_w / screen.width
    sw, sh = screen_w, round(screen.height * s)
    shot = screen.convert("RGB").resize((sw, sh), Image.LANCZOS)
    # Dynamic Island (iPhone 17: ~126x37 pt at y=11, 3x scale)
    d = ImageDraw.Draw(shot)
    iw, ih, iy = 126 * 3 * s, 37 * 3 * s, 11 * 3 * s
    d.rounded_rectangle([(sw - iw) / 2, iy, (sw + iw) / 2, iy + ih], ih / 2, fill=(0, 0, 0))

    ow, oh = sw + 2 * BEZEL, sh + 2 * BEZEL
    r_out = round(RADIUS * screen_w / SCREEN_W)
    frame = Image.new("RGBA", (ow, oh), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.rounded_rectangle([0, 0, ow - 1, oh - 1], r_out, fill=(58, 60, 66, 255))
    fd.rounded_rectangle([3, 3, ow - 4, oh - 4], r_out - 3, fill=(22, 23, 26, 255))
    fd.rounded_rectangle([BEZEL - 6, BEZEL - 6, ow - BEZEL + 5, oh - BEZEL + 5], r_out - BEZEL + 6, fill=(0, 0, 0, 255))
    frame.paste(shot, (BEZEL, BEZEL), rounded_mask((sw, sh), r_out - BEZEL))
    return frame


def shadowed(canvas, img, pos, accent):
    x, y = pos
    pad = 120
    sh = Image.new("L", (img.width + 2 * pad, img.height + 2 * pad), 0)
    sh.paste(img.getchannel("A").point(lambda v: 200 if v else 0), (pad, pad))
    sh = sh.filter(ImageFilter.GaussianBlur(50))
    tint = Image.new("RGB", sh.size, tuple(int(c * 0.35) for c in accent))
    canvas.paste(tint, (x - pad, y - pad + 30), sh)
    canvas.paste(img, (x, y), img)


def slide(raw, headline, subtitle, accent):
    canvas = background(W, H, accent, (W // 2, 900, 620))
    d = ImageDraw.Draw(canvas)
    hf = fitted_font(headline, 104, "Bold", W - 2 * MARGIN)
    sf = fitted_font(subtitle, 46, "Regular", W - 2 * MARGIN)
    d.text((W / 2, 190), headline, font=hf, fill=(255, 255, 255), anchor="ms")
    d.text((W / 2, 268), subtitle, font=sf, fill=(170, 174, 184), anchor="ms")
    # small accent bar above the headline
    d.rounded_rectangle([W / 2 - 34, 82, W / 2 + 34, 90], 4, fill=accent)
    phone = device(raw)
    shadowed(canvas, phone, ((W - phone.width) // 2, 360), accent)
    # fade the bottom edge so the cut-off phone ends softly
    fade_h = 260
    fade = Image.new("L", (W, fade_h))
    for yy in range(fade_h):
        ImageDraw.Draw(fade).line([(0, yy), (W, yy)], fill=int(255 * (yy / fade_h) ** 1.6))
    canvas.paste(Image.new("RGB", (W, fade_h), (4, 5, 8)), (0, H - fade_h), fade)
    return canvas


def banner(raws):
    bw, bh = 2400, 1000
    accent = (10, 132, 255)
    canvas = background(bw, bh, accent, (1650, 520, 520))
    d = ImageDraw.Draw(canvas)
    d.text((150, 420), "Erup", font=font(190, "Bold"), fill=(255, 255, 255), anchor="ls")
    text_w = 940
    d.text((156, 515), "The companion app for the Pure Flex", font=fitted_font("The companion app for the Pure Flex", 56, "Medium", text_w), fill=(210, 214, 222), anchor="ls")
    for i, line in enumerate(["Live dashboard, rides and routes,", "battery health, alerts and backup.", "Native iOS, sideloaded with AltStore."]):
        d.text((156, 600 + i * 60), line, font=fitted_font(line, 42, "Regular", text_w), fill=(140, 145, 158), anchor="ls")
    order = [("map", 1400, 190, 480), ("battery", 2110, 190, 480), ("dashboard", 1755, 90, 560)]
    for name, cx, top, sw in order:
        if name not in raws:
            continue
        ph = device(raws[name], screen_w=sw)
        shadowed(canvas, ph, (cx - ph.width // 2, top), accent)
    fade_h = 180
    fade = Image.new("L", (bw, fade_h))
    for yy in range(fade_h):
        ImageDraw.Draw(fade).line([(0, yy), (bw, yy)], fill=int(255 * (yy / fade_h) ** 1.6))
    canvas.paste(Image.new("RGB", (bw, fade_h), (4, 5, 8)), (0, bh - fade_h), fade)
    return canvas


def save(img, path, limit=700_000):
    img.save(path, optimize=True)
    if path.stat().st_size > limit:
        img.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG).save(path, optimize=True)
    print(f"{path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}: {path.stat().st_size // 1024} KB")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "docs" / "screenshots"
    out.mkdir(parents=True, exist_ok=True)
    raws = {}
    for name, headline, subtitle, accent in SLIDES:
        f = src / f"{name}.png"
        if not f.exists():
            print(f"skip {name}: {f} missing")
            continue
        raws[name] = Image.open(f)
        save(slide(raws[name], headline, subtitle, accent), out / f"{name}.png")
    save(banner(raws), out / "banner.png")


if __name__ == "__main__":
    main()
