#!/usr/bin/env python3
"""Draws the app icon and writes Assets/AppIcon.svg and Assets/AppIcon.icns.

Needs rsvg-convert (brew install librsvg). Small sizes get heavier lines and no stars, so they stay readable.
"""
import pathlib, subprocess, sys, tempfile

GROUND, RAISED, LINE, TEXT, GOLD, BLUE = "#0F1115", "#1D2331", "#2B3242", "#E8EBF1", "#E8B830", "#8BABFF"


def sparkle(x, y, size, colour):
    w = size * 0.16
    return (f'<path d="M{x} {y - size} Q{x + w} {y - w} {x + size} {y} Q{x + w} {y + w} {x} {y + size} '
            f'Q{x - w} {y + w} {x - size} {y} Q{x - w} {y - w} {x} {y - size} Z" fill="{colour}"/>')


def svg(line, stars, scale):
    rocket = f'''
    <g fill="none" stroke="{TEXT}" stroke-width="{line}" stroke-linecap="round" stroke-linejoin="round">
      <path d="M0 -286 C46 -226 96 -130 96 -34 C96 28 86 78 70 120 L-70 120 C-86 78 -96 28 -96 -34 C-96 -130 -46 -226 0 -286 Z"/>
      <path d="M95 -14 C130 12 170 60 176 152 C150 130 112 120 78 104"/>
      <path d="M-95 -14 C-130 12 -170 60 -176 152 C-150 130 -112 120 -78 104"/>
      <circle cx="0" cy="-62" r="46"/>
      <path d="M-46 120 L-34 172 L34 172 L46 120"/>
    </g>
    <g fill="none" stroke="{GOLD}" stroke-width="{line}" stroke-linecap="round">
      <path d="M0 222 L0 300"/>
      <path d="M-52 218 L-52 260"/>
      <path d="M52 218 L52 260"/>
    </g>'''
    extras = "".join([sparkle(300, 318, 40, BLUE), sparkle(724, 716, 28, BLUE), sparkle(262, 520, 16, TEXT),
                      f'<circle cx="548" cy="238" r="9" fill="{TEXT}"/>', f'<circle cx="770" cy="520" r="9" fill="{GOLD}"/>']) if stars else ""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{RAISED}"/><stop offset="1" stop-color="{GROUND}"/></linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#3D6CF0" stop-opacity="0.30"/><stop offset="1" stop-color="#3D6CF0" stop-opacity="0"/></radialGradient>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%"><feGaussianBlur stdDeviation="14"/></filter>
  </defs>
  <rect x="100" y="112" width="824" height="824" rx="185" fill="#000" opacity="0.32" filter="url(#shadow)"/>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#tile)"/>
  <rect x="103" y="103" width="818" height="818" rx="182" fill="none" stroke="{LINE}" stroke-width="6"/>
  <circle cx="512" cy="512" r="340" fill="url(#glow)"/>{extras}
  <g transform="translate(512 512) rotate(45) scale({scale}) translate(0 -8)">{rocket}
  </g>
</svg>
'''


def render(source, pixels, out):
    subprocess.run(["rsvg-convert", "-w", str(pixels), "-h", str(pixels), "-o", str(out), str(source)], check=True)


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    assets = root / "Assets"
    assets.mkdir(exist_ok=True)
    (assets / "AppIcon.svg").write_text(svg(24, True, 1.0))
    with tempfile.TemporaryDirectory() as folder:
        folder = pathlib.Path(folder)
        full, medium, small = folder / "full.svg", folder / "medium.svg", folder / "small.svg"
        full.write_text(svg(24, True, 1.0))
        medium.write_text(svg(36, False, 1.08))
        small.write_text(svg(58, False, 1.12))
        iconset = folder / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for factor, suffix in ((1, ""), (2, "@2x")):
                pixels = points * factor
                source = small if pixels <= 32 else medium if pixels <= 64 else full
                render(source, pixels, iconset / f"icon_{points}x{points}{suffix}.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(assets / "AppIcon.icns")], check=True)
        if len(sys.argv) > 1:
            preview = pathlib.Path(sys.argv[1])
            preview.mkdir(parents=True, exist_ok=True)
            for pixels, source in ((1024, full), (256, full), (128, full), (64, medium), (32, small), (16, small)):
                render(source, pixels, preview / f"{pixels}.png")


main()
