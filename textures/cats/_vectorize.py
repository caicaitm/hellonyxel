"""Bitmap -> SVG vectorizer: color layers, run-length polygon extraction, Douglas-Peucker."""
import numpy as np
from scipy import ndimage


def runs_rows(mask):
    """Yield (y, x0, x1) horizontal runs of True pixels (x1 exclusive)."""
    H, W = mask.shape
    for y in range(H):
        row = mask[y]
        if not row.any():
            continue
        d = np.diff(np.concatenate(([0], row.view(np.int8), [0])))
        starts = np.where(d == 1)[0]
        ends = np.where(d == -1)[0]
        for s, e in zip(starts, ends):
            yield y, int(s), int(e)


def mask_to_polys(mask, eps=1.1, min_area=25.0):
    """Convert a boolean mask into simplified closed polygons [(x,y), ...].

    Uses the marching-squares style mid-pixel contour via subpixel edge segments,
    simplified with Douglas-Peucker. Handles holes as separate polygons.
    """
    lab, n = ndimage.label(mask)
    polys = []
    for i in range(1, n + 1):
        comp = lab == i
        if comp.sum() < 4:
            continue
        for poly in _component_contours(comp):
            if len(poly) >= 3:
                p = np.asarray(poly, dtype=float)
                area = 0.5 * abs(np.dot(p[:, 0], np.roll(p[:, 1], 1)) - np.dot(p[:, 1], np.roll(p[:, 0], 1)))
                if area < min_area:
                    continue
                polys.append(_dp_closed(p, eps))
    return polys


def _component_contours(comp):
    """Marching-squares contours of a single connected component at iso 0.5."""
    pad = np.pad(comp, 1, mode="constant")
    H, W = pad.shape
    # edges: horizontal edges between (y-1,x) and (y,x); vertical between (y,x-1),(y,x)
    # build directed segments with square interior on the left (clockwise in image coords)
    segs = {}
    ys, xs = np.where(pad)
    for y, x in zip(ys, xs):
        if not pad[y - 1, x]:
            segs.setdefault((x, y), []).append((x + 1, y))
        if not pad[y + 1, x]:
            segs.setdefault((x + 1, y + 1), []).append((x, y + 1))
        if not pad[y, x - 1]:
            segs.setdefault((x, y + 1), []).append((x, y))
        if not pad[y, x + 1]:
            segs.setdefault((x + 1, y), []).append((x + 1, y + 1))
    contours = []
    while segs:
        start = next(iter(segs))
        cur = start
        poly = [start]
        guard = 0
        while guard < 10_000_000:
            guard += 1
            nxt = segs.get(cur)
            if not nxt:
                break
            n = nxt.pop()
            if not nxt:
                del segs[cur]
            cur = n
            if cur == start:
                break
            poly.append(cur)
        if len(poly) >= 3:
            contours.append([(x - 1, y - 1) for x, y in poly])
    return contours


def _dp_closed(p, eps):
    n = len(p)
    if n < 4:
        return p
    d = np.linalg.norm(p - p[0], axis=1)
    i1 = int(np.argmax(d))
    if i1 == 0:
        return p
    a = _dp(p[: i1 + 1], eps)
    b = _dp(np.vstack([p[i1:], p[:1]]), eps)
    return np.vstack([a[:-1], b[:-1]])


def _dp(p, eps):
    if len(p) < 3:
        return p
    a, b = p[0], p[-1]
    ab = b - a
    L = np.hypot(*ab)
    if L == 0:
        d = np.linalg.norm(p - a, axis=1)
    else:
        d = np.abs(ab[0] * (p[:, 1] - a[1]) - ab[1] * (p[:, 0] - a[0])) / L
    i = int(np.argmax(d))
    if d[i] > eps:
        return np.vstack([_dp(p[: i + 1], eps)[:-1], _dp(p[i:], eps)])
    return np.array([a, b])
