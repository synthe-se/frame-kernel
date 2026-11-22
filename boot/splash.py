"""The frame's boot pictures. U-Boot draws Synthèse's mark from the first second (`logo()`); once
Linux has the panel, the initramfs draws the product's own picture on /dev/fb0, which the slot it
starts carries (`product()`: `splash.raw` and where the loader's ring turns, `splash.conf`), and
nothing else. A slot without one, or no slot at all, gets the frame's own (`builtin()`):
Synthèse's mark, and under it, only when nothing can start, a line that says so.

Raw XRGB8888 as the framebuffer holds it (800×1280, 3200 bytes a row). A picture is drawn as the
person sees it and turned onto the panel by the product's TURN, a quarter clockwise at a time:
180 for a frame standing in portrait (the panel is mounted upside down), 90 for one lying on its
side with the picture's top at the panel's right edge. Rendered with rsvg-convert, which does the
turning too.

    python3 boot/splash.py logo <resource.img> <out.img>        U-Boot's picture, in a resource image
    python3 boot/splash.py product <product directory> <out directory>
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import bootimg  # noqa: E402
import png  # noqa: E402

W, H = 800, 1280
STRIDE = W * 4
# the frame's own picture: Synthèse's colours, standing in portrait
CLOUD, PETROL, INK_SOFT = "#f2f0ea", "#0e5e68", "#525a66"
BUILTIN_TURN = 180
# Synthèse's S fills 92 of its 128 units: scaled so that the S itself is 240 high
SYNTHESE_HEIGHT = 240 * 128 / 92
MISSING = "Système introuvable : branche le cadre à un ordinateur pour le réinstaller."
# the failure's line: a strip of its own, copied over the picture (in what the person sees)
STRIP_Y, STRIP_H = 900, 64


def seen(turn: int) -> tuple[int, int]:
    """The picture's size as the person sees it."""
    return (W, H) if turn in (0, 180) else (H, W)


def onto_panel(turn: int) -> str:
    """The SVG transform that lays the picture as seen onto the framebuffer."""
    return {0: "", 90: f"translate({W} 0) rotate(90)", 180: f"translate({W} {H}) rotate(180)", 270: f"translate(0 {H}) rotate(270)"}[turn]


def point(turn: int, x: float, y: float) -> tuple[int, int]:
    """Where a point of the picture as seen lands in the framebuffer."""
    px, py = {0: (x, y), 90: (W - y, x), 180: (W - x, H - y), 270: (y, H - x)}[turn]
    return int(px), int(py)


def render(svg: str, w: int, h: int) -> list[bytes]:
    """`svg` as RGB rows, `w`×`h`."""
    with tempfile.TemporaryDirectory() as d:
        src, out = Path(d, "in.svg"), Path(d, "out.png")
        src.write_text(svg)
        subprocess.run(["rsvg-convert", "-w", str(w), "-h", str(h), "-o", str(out), str(src)], check=True)
        rw, rh, rows = png.png_rows(out.read_bytes())
    if (rw, rh) != (w, h):
        raise SystemExit(f"splash: {rw}×{rh} rendered, {w}×{h} wanted")
    return rows


def raw(rows: list[bytes]) -> bytes:
    """RGB rows as the framebuffer's XRGB8888 (bytes B, G, R, X)."""
    out = bytearray()
    for row in rows:
        for i in range(0, len(row), 3):
            out += bytes((row[i + 2], row[i + 1], row[i], 0))
    return bytes(out)


def layout(turn: int, mark_height: float) -> tuple[float, float]:
    """Where the mark's top is, and the loader's centre under it, down the picture as seen: the
    mark a little above the middle, the ring a fifth of the height under it."""
    _, h = seen(turn)
    top = (h - mark_height) / 2 - h / 16
    return top, top + mark_height + h * 252 / 1280


def picture(mark: str, ground: str, turn: int, mark_height: float, top: float | None = None) -> str:
    """The whole panel's SVG: `mark` (an SVG's text) `mark_height` high and centred, on `ground`."""
    box = re.search(r'viewBox="([-0-9. ]+)"', mark)
    if not box:
        raise SystemExit("splash: the mark has no viewBox")
    _, _, bw, bh = (float(v) for v in box[1].split())
    inner = mark[mark.index(">", mark.index("<svg")) + 1 : mark.rindex("</svg>")]
    w, _ = seen(turn)
    width = mark_height * bw / bh
    y = layout(turn, mark_height)[0] if top is None else top
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">'
        f'<rect width="{W}" height="{H}" fill="{ground}"/><g transform="{onto_panel(turn)}">'
        f'<svg x="{(w - width) / 2}" y="{y}" width="{width}" height="{mark_height}" viewBox="{box[1]}" fill="none">{inner}</svg>'
        f"</g></svg>"
    )


def loader(turn: int, mark_height: float, ground: str, ink: str) -> str:
    """The loader's arguments: its centre in the framebuffer, its two colours, how long at most."""
    w, _ = seen(turn)
    x, y = point(turn, w / 2, layout(turn, mark_height)[1])
    return f"{x} {y} 0x{ground[1:]} 0x{ink[1:]} 120"


def synthese() -> str:
    """Synthèse's mark where a product's comes next: its S as high as a 240 mark, on the same centre."""
    mark = (HERE / "synthese-mark.svg").read_text()
    return picture(mark, CLOUD, BUILTIN_TURN, SYNTHESE_HEIGHT, layout(BUILTIN_TURN, 240)[0] + (240 - SYNTHESE_HEIGHT) / 2)


def logo() -> bytes:
    """What U-Boot draws, the same picture as the frame's own: `logo.bmp`."""
    return png.bmp24(W, H, render(synthese(), W, H))


def builtin() -> dict[str, bytes]:
    """The frame's own: `splash.raw`, `splash.conf`, and the failure's strip with where it goes."""
    text = MISSING.replace("&", "&amp;").replace("<", "&lt;")
    strip = (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{STRIP_H}">'
        f'<rect width="{W}" height="{STRIP_H}" fill="{CLOUD}"/><g transform="translate({W} {STRIP_H}) rotate(180)">'
        f'<text x="{W // 2}" y="{STRIP_H // 2 + 9}" text-anchor="middle" fill="{INK_SOFT}" '
        f'font-family="Helvetica Neue, Helvetica, Arial, sans-serif" font-size="26">{text}</text></g></svg>'
    )
    return {
        "splash.raw": raw(render(synthese(), W, H)),
        "splash.conf": (loader(BUILTIN_TURN, 240, CLOUD, PETROL) + "\n").encode(),
        "missing.raw": raw(render(strip, W, STRIP_H)),
    }


# the framebuffer's row where the failure's strip starts, the frame standing in portrait
STRIP_ROW = H - (STRIP_Y + STRIP_H)


def conf(directory: Path) -> dict[str, str]:
    """A product's product.conf: KEY=value lines, as bin/product.sh reads them."""
    said = {}
    for line in (directory / "product.conf").read_text().splitlines():
        found = re.match(r"([A-Z_]+)=(.*)$", line.strip())
        if found:
            said[found[1]] = found[2].strip("'\"")
    return said


def product(directory: Path) -> dict[str, bytes]:
    """A product's boot picture, what its slot carries: `splash.raw` and `splash.conf`."""
    said = conf(directory)
    turn, height = int(said.get("TURN", "0")), float(said.get("MARK_HEIGHT", "240"))
    ground, ink = said["GROUND"], said["INK"]
    for colour in (ground, ink):
        if not re.fullmatch(r"#[0-9a-fA-F]{6}", colour):
            raise SystemExit(f"{directory}/product.conf: {colour} is no #rrggbb")
    mark = (directory / said["MARK"]).read_text()
    return {
        "splash.raw": raw(render(picture(mark, ground, turn, height), W, H)),
        "splash.conf": (loader(turn, height, ground, ink) + "\n").encode(),
    }


def main() -> int:
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == "logo":
        Path(args[2]).write_bytes(bootimg.rsce_put(Path(args[1]).read_bytes(), "logo.bmp", logo()))
        return 0
    if len(args) == 3 and args[0] == "product":
        out = Path(args[2])
        out.mkdir(parents=True, exist_ok=True)
        for name, data in product(Path(args[1])).items():
            (out / name).write_bytes(data)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
