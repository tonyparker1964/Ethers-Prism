"""Sculpt 3D core: pure numpy. Picture -> subject mask -> rounded height field (front) for an inflated model."""
import numpy as np


def box_blur(a, r):
    if r <= 0:
        return a
    k = 2 * r + 1
    pad = [(r, r), (0, 0)] + [(0, 0)] * (a.ndim - 2)
    c = np.cumsum(np.pad(a, pad, mode='edge'), axis=0)
    c = np.concatenate([c[k - 1:k], c[k:] - c[:-k]], axis=0) / k
    pad = [(0, 0), (r, r)] + [(0, 0)] * (a.ndim - 2)
    c2 = np.cumsum(np.pad(c, pad, mode='edge'), axis=1)
    return np.concatenate([c2[:, k - 1:k], c2[:, k:] - c2[:, :-k]], axis=1) / k


def resize(img, w, h):
    H, W = img.shape[:2]
    f = max(W / w, H / h)
    if f > 1.5:
        img = box_blur(img, int(f / 2))
    ys = ((np.arange(h) + 0.5) * H / h).astype(int).clip(0, H - 1)
    xs = ((np.arange(w) + 0.5) * W / w).astype(int).clip(0, W - 1)
    return img[ys][:, xs]


def subject_mask(rgb, alpha=None, tolerance=0.18):
    """The subject: from transparency if the picture has it, else everything unlike the border colour.
    Returns (mask, cut_out): cut_out is False when the picture fills its frame (no plain background)."""
    if alpha is not None and alpha.min() < 0.5 and alpha.mean() < 0.97:
        m = alpha > 0.5
    else:
        border = np.concatenate([rgb[0], rgb[-1], rgb[:, 0], rgb[:, -1]])
        bg = np.median(border, axis=0)
        spread = np.percentile(np.abs(border - bg).sum(1), 75)
        diff = np.abs(box_blur(rgb, 1) - bg).sum(2)
        m = diff > max(tolerance, spread * 2.5)
        # a busy border or a result that is nearly all or nothing means there's no plain background
        if spread > 0.2 or m.mean() > 0.92 or m.mean() < 0.08:
            m = np.ones(rgb.shape[:2], bool)
            m[0, :] = m[-1, :] = False
            m[:, 0] = m[:, -1] = False
            return m, False
    # tidy: close small gaps, drop specks
    soft = box_blur(m.astype(np.float32), 2)
    m = soft > 0.5
    m[0, :] = m[-1, :] = False
    m[:, 0] = m[:, -1] = False
    return m, True


def distance_inside(mask, limit=400):
    """Approximate distance (pixels) from each inside pixel to the edge (chamfer, iterated)."""
    INF = 1e6
    d = np.where(mask, INF, 0.0)
    steps = [(0, 1, 1.0), (0, -1, 1.0), (1, 0, 1.0), (-1, 0, 1.0),
             (1, 1, 1.4142), (1, -1, 1.4142), (-1, 1, 1.4142), (-1, -1, 1.4142)]
    for _ in range(limit):
        prev = d
        for dy, dx, w in steps:
            sh = np.full_like(d, INF)
            ys = slice(max(dy, 0), d.shape[0] + min(dy, 0)); yd = slice(max(-dy, 0), d.shape[0] + min(-dy, 0))
            xs = slice(max(dx, 0), d.shape[1] + min(dx, 0)); xd = slice(max(-dx, 0), d.shape[1] + min(-dx, 0))
            sh[ys, xs] = d[yd, xd] + w
            d = np.minimum(d, sh)
        if np.array_equal(d, prev):
            break
    return np.where(mask, d, 0.0)


def height_field(rgb, mask, inflate=1.0, detail=0.25, smooth=2):
    """Rounded 'pillow' height from the distance to the edge, plus a little relief from the picture's light."""
    d = distance_inside(mask)
    R = max(d.max(), 1.0)
    t = np.clip(d / R, 0, 1)
    round_ = np.sqrt(np.clip(t * (2 - t), 0, 1))          # circular profile: steep at the edge, flat on top
    h = round_ * inflate
    lum = box_blur(rgb.mean(2), smooth)
    rel = (lum - lum[mask].mean()) if mask.any() else lum * 0
    h = h + rel * detail * np.clip(t * 4, 0, 1)            # relief fades out at the edge
    h = box_blur(h, 1)
    return np.where(mask, np.maximum(h, 0), 0.0), R
