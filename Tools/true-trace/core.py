"""True Trace core: pure numpy, no bpy. Turns an image into filled regions + ink lines for a look.

The same functions are pasted into the Blender script; this file lets us test them anywhere.
"""
import math
import numpy as np


# ------------------------------------------------------------------ image helpers
def box_blur(a, r):
    """Separable box blur, radius r (pixels), any number of channels."""
    if r <= 0:
        return a
    k = 2 * r + 1
    pad = [(r, r), (0, 0)] + [(0, 0)] * (a.ndim - 2)
    c = np.cumsum(np.pad(a, pad, mode='edge'), axis=0)
    c = np.concatenate([c[k - 1:k], c[k:] - c[:-k]], axis=0) / k
    pad = [(0, 0), (r, r)] + [(0, 0)] * (a.ndim - 2)
    c2 = np.cumsum(np.pad(c, pad, mode='edge'), axis=1)
    return np.concatenate([c2[:, k - 1:k], c2[:, k:] - c2[:, :-k]], axis=1) / k


def resize(rgb, w, h):
    """Area-ish resize by sampling a blurred image (good enough for downscaling)."""
    H, W = rgb.shape[:2]
    f = max(W / w, H / h)
    if f > 1.5:
        rgb = box_blur(rgb, int(f / 2))
    ys = ((np.arange(h) + 0.5) * H / h).astype(int).clip(0, H - 1)
    xs = ((np.arange(w) + 0.5) * W / w).astype(int).clip(0, W - 1)
    return rgb[ys][:, xs]


def adjust(rgb, saturation=1.0, contrast=1.0, brightness=0.0):
    grey = rgb.mean(axis=2, keepdims=True)
    out = grey + (rgb - grey) * saturation
    out = (out - 0.5) * contrast + 0.5 + brightness
    return out.clip(0, 1)


def smooth_preserving(rgb, iterations=2, radius=2, edge=0.12):
    """Cheap edge-preserving smoothing: blend toward the blur only where the image is flat."""
    out = rgb
    for _ in range(iterations):
        b = box_blur(out, radius)
        diff = np.abs(out - b).sum(axis=2, keepdims=True)
        w = np.clip(1 - diff / edge, 0, 1)
        out = out * (1 - w) + b * w
    return out


# ------------------------------------------------------------------ quantize
def to_space(rgb):
    y = rgb @ np.array([0.299, 0.587, 0.114])
    return np.stack([y * 1.6, (rgb[..., 2] - y) * 1.1, (rgb[..., 0] - y) * 1.1], -1)


def kmeans_colors(rgb, k, seed=7, iters=12, sample=40000):
    space = to_space(rgb)
    flat = space.reshape(-1, 3)
    rng = np.random.default_rng(seed)
    pick = flat[rng.choice(len(flat), size=min(sample, len(flat)), replace=False)]
    # k-means++ start
    centers = [pick[rng.integers(len(pick))]]
    for _ in range(1, k):
        d = np.min(((pick[:, None, :] - np.array(centers)[None]) ** 2).sum(2), axis=1)
        centers.append(pick[rng.choice(len(pick), p=d / d.sum())] if d.sum() > 0 else pick[rng.integers(len(pick))])
    c = np.array(centers)
    for _ in range(iters):
        lab = np.argmin(((pick[:, None, :] - c[None]) ** 2).sum(2), axis=1)
        for j in range(k):
            m = pick[lab == j]
            if len(m):
                c[j] = m.mean(0)
    labels = np.empty(len(flat), dtype=np.int32)
    for s in range(0, len(flat), 200000):
        labels[s:s + 200000] = np.argmin(((flat[s:s + 200000, None, :] - c[None]) ** 2).sum(2), axis=1)
    labels = labels.reshape(rgb.shape[:2])
    rgbflat = rgb.reshape(-1, 3)
    colours = np.array([rgbflat[labels.ravel() == j].mean(0) if (labels == j).any() else np.zeros(3) for j in range(k)])
    return colours, labels


def majority(labels, k, passes=2, radius=1):
    """Each pixel takes the most common label around it: removes speckles, rounds shapes."""
    for _ in range(passes):
        best = np.zeros(labels.shape, dtype=np.float32) - 1
        out = labels.copy()
        for j in range(k):
            cnt = box_blur((labels == j).astype(np.float32), radius)
            take = cnt > best
            out[take] = j
            best = np.maximum(best, cnt)
        labels = out
    return labels


def cel_shade(rgb, centers, labels, levels):
    """Snap each palette colour's lightness to a few cel levels (anime-style flat shadows)."""
    if levels <= 0:
        return centers
    c = centers.copy()
    lum = c.mean(1, keepdims=True).clip(1e-4, 1)
    step = np.round(lum * levels) / levels
    step = np.where(lum < 0.1, lum, np.clip(step, 0.5 / levels, 1))   # keep near-black as it is
    return (c * (step / lum)).clip(0, 1)


# ------------------------------------------------------------------ contours
def contours(v, t):
    """Marching squares on field v at threshold t. Returns closed polylines in pixel coordinates."""
    h, w = v.shape
    b = (v > t).astype(np.uint8)
    case = b[:-1, :-1] * 1 + b[:-1, 1:] * 2 + b[1:, 1:] * 4 + b[1:, :-1] * 8

    def lerp(a, c):
        d = c - a
        return 0.5 if abs(d) < 1e-9 else (t - a) / d

    def pt(i, j, e):
        if e == 0: return (j + lerp(v[i, j], v[i, j + 1]), i)
        if e == 1: return (j + 1, i + lerp(v[i, j + 1], v[i + 1, j + 1]))
        if e == 2: return (j + lerp(v[i + 1, j], v[i + 1, j + 1]), i + 1)
        return (j, i + lerp(v[i, j], v[i + 1, j]))

    # edges: 0 top, 1 right, 2 bottom, 3 left. Segment table (directed so inside is on the left in image coords).
    table = {1: [(3, 0)], 2: [(0, 1)], 3: [(3, 1)], 4: [(1, 2)], 5: [(3, 2), (1, 0)], 6: [(0, 2)], 7: [(3, 2)],
             8: [(2, 3)], 9: [(2, 0)], 10: [(0, 3), (2, 1)], 11: [(2, 1)], 12: [(1, 3)], 13: [(1, 0)], 14: [(0, 3)]}
    nxt = {}
    for i, j in zip(*np.nonzero((case > 0) & (case < 15))):
        for e0, e1 in table[int(case[i, j])]:
            key = (i, j, e0)
            nxt[key] = (i, j, e1)
    # an exit edge (i,j,e1) is the same as the neighbour's entry edge
    def neighbour(i, j, e):
        if e == 0: return (i - 1, j, 2)
        if e == 1: return (i, j + 1, 3)
        if e == 2: return (i + 1, j, 0)
        return (i, j - 1, 1)

    seen = set()
    out = []
    for start in list(nxt.keys()):
        if start in seen:
            continue
        chain = []
        cur = start
        while cur in nxt and cur not in seen:
            seen.add(cur)
            i, j, e0 = cur
            chain.append(pt(i, j, e0))
            i, j, e1 = nxt[cur]
            cur = neighbour(i, j, e1)
        if len(chain) >= 3:
            out.append(chain)
    return out


def rdp(pts, eps):
    if len(pts) < 4 or eps <= 0:
        return pts
    p = np.array(pts)
    s, e = p[0], p[-1]
    d = e - s
    n = math.hypot(*d)
    if n < 1e-9:
        dist = np.hypot(*(p - s).T)
    else:
        dist = np.abs(d[0] * (p[:, 1] - s[1]) - d[1] * (p[:, 0] - s[0])) / n
    i = int(np.argmax(dist))
    if dist[i] > eps:
        return rdp(pts[:i + 1], eps)[:-1] + rdp(pts[i:], eps)
    return [pts[0], pts[-1]]


def simplify_closed(pts, eps):
    if len(pts) < 6:
        return pts
    m = len(pts) // 2
    out = rdp(pts[:m + 1], eps)[:-1] + rdp(pts[m:] + [pts[0]], eps)[:-1]
    return out if len(out) >= 3 else pts


def signed_area(pts):
    x = np.array([p[0] for p in pts]); y = np.array([p[1] for p in pts])
    return 0.5 * float(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))


def chaikin(pts, n=1):
    for _ in range(n):
        p = np.array(pts)
        q = np.roll(p, -1, axis=0)
        pts = [tuple(v) for pair in zip(0.75 * p + 0.25 * q, 0.25 * p + 0.75 * q) for v in pair]
    return pts


# ------------------------------------------------------------------ the trace
def trace(rgb, r):
    """rgb: HxWx3 floats 0-1 (already at working size). r: recipe dict. Returns dict with fills and lines."""
    img = adjust(rgb, r.get('saturation', 1), r.get('contrast', 1), r.get('brightness', 0))
    img = smooth_preserving(img, r.get('smooth_passes', 2), r.get('smooth_radius', 2), r.get('smooth_edge', 0.15))
    k = int(r.get('colors', 12))
    centers, labels = kmeans_colors(img, k, seed=r.get('seed', 7))
    labels = majority(labels, k, passes=r.get('majority_passes', 2), radius=r.get('majority_radius', 1))
    palette = cel_shade(img, centers, labels, r.get('cel_levels', 0))
    if r.get('palette_saturation', 1) != 1:
        palette = adjust(palette[None], r['palette_saturation'])[0]

    H, W = labels.shape
    min_area = r.get('min_area', 12)
    eps = r.get('simplify', 0.8)
    fills = []
    for j in range(k):
        mask = np.pad((labels == j).astype(np.float32), 1)
        if mask.sum() < min_area:
            continue
        field = box_blur(mask, r.get('round', 1)) if r.get('round', 1) > 0 else mask
        for chain in contours(field, 0.5):
            a = signed_area(chain)
            if abs(a) < min_area:
                continue
            # outer boundary iff the enclosed side is inside the mask
            (x0, y0), (x1, y1) = chain[0], chain[1]
            dx, dy = x1 - x0, y1 - y0
            n = math.hypot(dx, dy) or 1
            side = 1 if a > 0 else -1           # enclosed side: left of travel when area > 0
            sx, sy = (x0 + x1) / 2 - side * dy / n * 0.8, (y0 + y1) / 2 + side * dx / n * 0.8
            iy, ix = int(round(sy)), int(round(sx))
            if not (0 <= iy < field.shape[0] and 0 <= ix < field.shape[1]) or field[iy, ix] < 0.5:
                continue  # a hole: other colours fill it
            pts = simplify_closed([(x - 1, y - 1) for x, y in chain], eps)
            if r.get('chaikin', 0):
                pts = chaikin(pts, r['chaikin'])
            fills.append({'pts': pts, 'area': abs(a), 'col': tuple(palette[j]), 'label': j})
    fills.sort(key=lambda f: -f['area'])  # painter: big shapes first, details on top

    lines = []
    if r.get('ink', 0) > 0 or r.get('sketch', True):
        pal = palette[labels]
        lumc = pal @ np.array([0.299, 0.587, 0.114])
        t, soft = r.get('ink_threshold', 0.18), r.get('ink_soft', 0.12)
        if r.get('ink', 0) <= 0:
            t, soft = -1.0, 1.0   # a pencil sketch: every outline, evenly
        for f in fills:
            if f['area'] < r.get('ink_min_area', 30):
                continue
            pts, strength = [], []
            n = len(f['pts'])
            for i in range(n):
                x0, y0 = f['pts'][i - 1]; x1, y1 = f['pts'][(i + 1) % n]
                x, y = f['pts'][i]
                dx, dy = x1 - x0, y1 - y0
                m = math.hypot(dx, dy) or 1
                ax, ay = int(round(x - dy / m * 1.6)), int(round(y + dx / m * 1.6))
                bx, by = int(round(x + dy / m * 1.6)), int(round(y - dx / m * 1.6))
                if 0 <= ax < W and 0 <= ay < H and 0 <= bx < W and 0 <= by < H:
                    jump = abs(lumc[ay, ax] - lumc[by, bx]) + 0.5 * np.abs(pal[ay, ax] - pal[by, bx]).sum()
                else:
                    jump = 1.0  # image border / silhouette
                pts.append((x, y))
                strength.append(float(np.clip((jump - t) / soft, 0, 1)))
            if max(strength) > 0:
                lines.append({'pts': pts, 'strength': strength, 'col': tuple(f['col']), 'len': len(pts)})
    return {'w': W, 'h': H, 'fills': fills, 'lines': lines, 'palette': palette}
