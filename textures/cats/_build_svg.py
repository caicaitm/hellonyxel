"""Final vectorizer v2: traced shapes + rebuilt colour layers (iris gradient, highlights, mouth)."""
import time
import numpy as np
from PIL import Image
from scipy import ndimage as ndi
import _vectorize as V

SRC = r"D:\.0MyProject\HelloNyxel\textures\cats\正面无底.png"
STROKE = "#8D5B5A"
OUT = r"D:\.0MyProject\HelloNyxel\textures\cats\正面无底.svg"


def d_of(polys, dx=0.0, dy=0.0):
    out = []
    for pts in polys:
        s = []
        for i, (x, y) in enumerate(pts):
            s.append(("M" if i == 0 else "L") + f"{x + dx:.1f} {y + dy:.1f}")
        out.append("".join(s) + "Z")
    return " ".join(out)


def main():
    t0 = time.time()
    a = np.array(Image.open(SRC).convert("RGBA")).astype(np.int16)
    r, g, b, al = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
    lum = r * 0.299 + g * 0.587 + b * 0.114
    sat = a[..., :3].max(2) - a[..., :3].min(2)
    H, W = al.shape
    op = al > 128

    stroke = op & (lum < 178)
    eye = op & (sat > 70) & (lum > 110) & (r > 150)
    # keep only the two large eye components
    lab, n = ndi.label(eye)
    sizes = ndi.sum(eye, lab, range(1, n + 1))
    keep = np.zeros_like(eye)
    for i, s in enumerate(sizes, 1):
        if s > 1500:
            keep |= lab == i
    eye = keep

    pink = op & (~stroke) & (~eye) & (sat > 14) & (sat < 68) & (r > 200) & ((r - b) > 26) & ((g - b) < 20)
    pink = ndi.binary_opening(pink, np.ones((3, 3)))
    pink = ndi.binary_closing(pink, np.ones((5, 5)))
    pink = ndi.binary_fill_holes(pink)
    plab, pn = ndi.label(pink)
    psz = ndi.sum(pink, plab, range(1, pn + 1))
    for i, s in enumerate(psz, 1):
        if s < 260:
            pink[plab == i] = False
    white = op & ~stroke & ~eye

    # --- housekeeping: remove leg-band artefacts from pink (hard-edged horizontal strips)
    ys, xs = np.where(pink)
    # --- stroke: thicken to restore true line weight, then trace
    # drop the mouth blob; it is redrawn as a smooth curve later
    slab, sn = ndi.label(stroke)
    for i in range(1, sn + 1):
        ys, xs = np.where(slab == i)
        if ys.min() > 540 and ys.max() < 570 and xs.min() > 700 and xs.max() < 780:
            stroke[slab == i] = False
    stroke_t = ndi.binary_dilation(stroke, ndi.generate_binary_structure(2, 1), 1)

    parts = []
    parts.append(f'  <path id="base" d="{d_of(V.mask_to_polys(op, 1.0, 60))}" fill="#FEFEFA"/>')
    if pink.any():
        parts.append(f'  <path id="pink" d="{d_of(V.mask_to_polys(pink, 1.0, 40))}" fill="#FBEDE2"/>')

    # eye layers: rebuilt smooth iris (4 flat bands) + one highlight per eye
    eyes = []
    elab, en = ndi.label(eye)
    for comp in ndi.find_objects(elab):
        if comp is None:
            continue
        sl_y, sl_x = comp
        x0, x1 = sl_x.start, sl_x.stop - 1
        y0, y1 = sl_y.start, sl_y.stop - 1
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        hw, hh = (x1 - x0) / 2, (y1 - y0) / 2
        eyes.append((cx, cy, hw, hh, x0, x1, y0, y1))

    parts.append(f'  <path id="stroke-fill" d="{d_of(V.mask_to_polys(stroke_t, 1.0, 18))}" fill="{STROKE}"/>')


    for k, (cx, cy, hw, hh, x0, x1, y0, y1) in enumerate(sorted(eyes, key=lambda t: t[4])):
        rr = hw * 0.82
        # capsule outline: rounded rect with a narrower top
        def capsule(inset=0.0, top=0.0, bot=0.0):
            w = hw - inset
            h = hh - inset
            hwd = w * 0.92
            hhd = h
            return (
                f"M{cx-hwd:.2f} {cy-hhd+top:.2f}"
                f"C{cx-hwd:.2f} {cy-hhd*0.55:.2f} {cx-hwd*0.62:.2f} {cy-hhd:.2f} {cx:.2f} {cy-hhd:.2f}"
                f"C{cx+hwd*0.62:.2f} {cy-hhd:.2f} {cx+hwd:.2f} {cy-hhd*0.55:.2f} {cx+hwd:.2f} {cy-hhd+top:.2f}"
                f"L{cx+hwd:.2f} {cy+hhd-bot:.2f}"
                f"C{cx+hwd:.2f} {cy+hhd*0.8:.2f} {cx+hwd*0.6:.2f} {cy+hhd:.2f} {cx:.2f} {cy+hhd:.2f}"
                f"C{cx-hwd*0.6:.2f} {cy+hhd:.2f} {cx-hwd:.2f} {cy+hhd*0.8:.2f} {cx-hwd:.2f} {cy+hhd-bot:.2f}Z"
            )

        cid = f"eyeclip{k}"
        dsh = capsule()
        parts.append(f'  <clipPath id="{cid}"><path d="{dsh}"/></clipPath>')
        # 4 flat bands, top -> bottom
        bands = [
            (0.00, 0.24, "#C4472B"),
            (0.24, 0.55, "#F58A33"),
            (0.55, 0.80, "#FFC15E"),
            (0.80, 1.00, "#FFE58C"),
        ]
        g = [f'<g clip-path="url(#{cid})">']
        for t0, t1, col in bands:
            ya = cy - hh + 2 * hh * t0
            yb = cy - hh + 2 * hh * t1
            g.append(f'<rect x="{cx-hw:.2f}" y="{ya:.2f}" width="{2*hw:.2f}" height="{yb-ya:.2f}" fill="{col}"/>')
        # dark rim along the very top of the iris
        g.append(f'<ellipse cx="{cx:.2f}" cy="{cy-hh-6:.2f}" rx="{hw*1.05:.2f}" ry="{hh*0.14:.2f}" fill="#B8432A" opacity="0.55"/>')
        g.append("</g>")
        parts.append("  " + "".join(g))
        parts.append(f'  <path d="{dsh}" fill="none" stroke="{STROKE}" stroke-width="3.4"/>')
        # single white highlight, upper area slightly left of centre
        parts.append(
            f'  <circle cx="{cx - hw*0.02:.2f}" cy="{cy - hh*0.50:.2f}" r="{hw*0.20:.2f}" fill="#FFFFFF"/>'
        )

    # mouth stroke (from original path, small)
        # mouth: one continuous smooth curve traced from the original centre-line
    parts.append(
        '  <path id="mouth" d="M725 556.1 C727.4 556.6 729.4 556.9 731.3 556.7 C732.8 556.5 734.0 556.0 735.3 555.2 C736.7 554.4 737.9 554.1 739.2 554.5 C740.5 554.9 741.6 555.3 742.9 555.8 C744.9 556.5 747.2 556.9 749.3 556.6 C750.9 556.3 752.1 555.8 753.0 555.4" fill="none" stroke="url(#mouthg)" stroke-width="1.55" stroke-linecap="round" stroke-linejoin="round"/>'
    )

    svg = "\n".join(
        [
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">',
            "  <title>HelloNyxel — 正面无底 (traced vector redraw)</title>",
            "  <desc>HelloNyxel cat girl, front view — vector redraw traced from 正面无底.png</desc>",
            "  <defs>",
            '    <linearGradient id="mouthg" x1="0" y1="0" x2="1" y2="0">',
            '      <stop offset="0" stop-color="#F6E9E4"/>',
            '      <stop offset="0.24" stop-color="#A97B6D"/>',
            '      <stop offset="0.42" stop-color="#845449"/>',
            '      <stop offset="0.58" stop-color="#845449"/>',
            '      <stop offset="0.78" stop-color="#A97B6D"/>',
            '      <stop offset="1" stop-color="#F6E9E4"/>',
            "    </linearGradient>",
            "  </defs>",
            *parts,
            "</svg>",
        ]
    )
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(svg)
    print("eyes found", len(eyes), [(e[1], e[2], e[3], e[4]) for e in eyes])
    print("bytes", len(svg), "time", round(time.time() - t0, 2))


if __name__ == "__main__":
    main()
