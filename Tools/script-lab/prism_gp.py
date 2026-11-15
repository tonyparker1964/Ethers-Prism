"""prism_gp — Ethers PRISM's brush and colour scripting library for Grease Pencil (Blender 5.x).

Write a few lines, PRISM's Script Lab runs them in Blender and shows the picture or video:

    canvas(1080, 1080, background="#f3ede1", seconds=4)
    ink  = brush("Ink", kind="ink", color="#151515", size=6)
    gold = brush("Gold", kind="marker", color="#e8b53a", size=14)
    circle(gold, (540, 400), 180)
    line(ink, (540, 580), (540, 900))
    draw_on()

Coordinates are canvas pixels, origin top-left, y down (like an image). Sizes are in pixels.
Colours are hex strings ("#e8b53a") or (r, g, b) in 0…1 sRGB.

Brushes are Grease Pencil materials (with a procedural texture for painterly kinds) plus a pressure
profile. Strokes are written as data (Blender's draw brushes can't be pressed from a script).
"""
import math
import random

import numpy as np

try:
    import bpy
except ImportError:          # planning functions work without Blender (tests)
    bpy = None

# --------------------------------------------------------------------------- colour

def _hex(c):
    """Any colour → (r, g, b) sRGB floats 0…1."""
    if isinstance(c, str):
        h = c.strip().lstrip("#")
        if len(h) == 3:
            h = "".join(ch * 2 for ch in h)
        return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
    c = tuple(float(v) for v in c)
    if max(c[:3]) > 1.0:                          # 0…255 given
        c = tuple(v / 255.0 for v in c)
    return c[:3]


def to_linear(c):
    """sRGB (0…1) → linear, which Blender's colours expect."""
    return tuple(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in _hex(c))


def color(c):
    """Normalises a colour to "#rrggbb"."""
    r, g, b = _hex(c)
    return "#%02x%02x%02x" % (round(r * 255), round(g * 255), round(b * 255))


def mix(a, b, t=0.5):
    """Mixes two colours (t = 0 → a, 1 → b)."""
    a, b = _hex(a), _hex(b)
    return color(tuple(x + (y - x) * t for x, y in zip(a, b)))


def lighten(c, amount=0.2):
    return mix(c, "#ffffff", amount)


def darken(c, amount=0.2):
    return mix(c, "#000000", amount)


def hsv(h, s, v):
    """Colour from hue (0…360), saturation and value (0…1)."""
    import colorsys
    return color(colorsys.hsv_to_rgb((h % 360) / 360.0, s, v))


def gradient(colors, t):
    """A colour along a list of colours (t 0…1)."""
    cs = [_hex(c) for c in colors]
    if len(cs) == 1:
        return color(cs[0])
    t = min(max(t, 0.0), 1.0) * (len(cs) - 1)
    i = min(int(t), len(cs) - 2)
    return mix(cs[i], cs[i + 1], t - i)


def palette_from(pixels, n=6, seed=1):
    """The n main colours of an image array (H×W×3, 0…1) by k-means."""
    px = np.asarray(pixels, dtype=np.float32).reshape(-1, 3)
    rng = np.random.default_rng(seed)
    if len(px) > 20000:
        px = px[rng.choice(len(px), 20000, replace=False)]
    cent = px[rng.choice(len(px), n, replace=False)]
    for _ in range(12):
        d = ((px[:, None, :] - cent[None, :, :]) ** 2).sum(-1)
        lab = d.argmin(1)
        for k in range(n):
            m = px[lab == k]
            if len(m):
                cent[k] = m.mean(0)
    counts = np.bincount(lab, minlength=n)
    return [color(tuple(cent[k])) for k in np.argsort(-counts)]


# --------------------------------------------------------------------------- brush textures

TEXTURES = ("solid", "pencil", "chalk", "bristle", "dry", "wash", "watercolor", "charcoal")

KINDS = {
    #             texture        pressure   taper  opacity  softness  line mode
    "ink":        ("solid",      "radius",  0.35,  1.0,     0.0,      "LINE"),
    "pen":        ("solid",      "none",    0.0,   1.0,     0.0,      "LINE"),
    "marker":     ("solid",      "none",    0.05,  0.85,    0.0,      "LINE"),
    "pencil":     ("pencil",     "both",    0.3,   0.8,     0.0,      "LINE"),
    "charcoal":   ("charcoal",   "both",    0.25,  0.85,    0.1,      "LINE"),
    "chalk":      ("chalk",      "both",    0.2,   0.9,     0.0,      "LINE"),
    "bristle":    ("bristle",    "radius",  0.3,   0.95,    0.0,      "LINE"),
    "oil":        ("bristle",    "radius",  0.25,  1.0,     0.0,      "LINE"),
    "dry":        ("dry",        "radius",  0.3,   0.9,     0.0,      "LINE"),
    "wash":       ("wash",       "radius",  0.15,  0.6,     0.5,      "LINE"),
    "watercolor": ("watercolor", "radius",  0.2,   0.8,     0.3,      "LINE"),
    "airbrush":   ("solid",      "opacity", 0.0,   0.25,    0.9,      "LINE"),
    "dots":       ("solid",      "none",    0.0,   1.0,     0.0,      "DOTS"),
    "squares":    ("solid",      "none",    0.0,   1.0,     0.0,      "BOX"),
}


def texture_pixels(kind, w=256, h=64, seed=7, rgb=(1.0, 1.0, 1.0)):
    """A brush texture as an h×w×4 array: colour `rgb` (sRGB 0…1), alpha carries the mark. x runs along the stroke.

    Blender colours a textured stroke from the texture itself, so each colour of a textured brush gets
    its own tinted copy (see _material_for)."""
    rng = np.random.default_rng(seed)
    y = np.linspace(-1, 1, h)[:, None]
    edge = np.clip(1 - np.abs(y) ** 6, 0, 1) * np.ones((1, w))

    def sm(v, k):
        ker = np.ones(k) / k
        return np.apply_along_axis(lambda r: np.convolve(np.r_[r[-k:], r, r[:k]], ker, "same")[k:-k], 1, v)

    if kind == "solid":
        a = np.clip(1 - np.abs(y) ** 12, 0, 1) * np.ones((1, w))
    elif kind == "pencil":
        a = edge * (0.7 + 0.3 * rng.random((h, w)))
    elif kind == "chalk":
        a = edge * np.where(rng.random((h, w)) > 0.3, 1.0, 0.15)
    elif kind == "charcoal":
        a = edge * np.clip(0.35 + (sm(rng.random((h, w)), 9) - 0.5) * 3, 0.15, 1)
    elif kind in ("bristle", "dry"):
        streak = np.clip(0.8 + (sm(rng.random((h, w)), 31) - 0.5) * 1.2 + (rng.random((h, 1)) - 0.5) * 0.6, 0.3, 1)
        a = edge * streak
        if kind == "dry":                                           # broken, scratchy
            a = a * np.where(sm(rng.random((h, w)), 15) > 0.42, 1.0, 0.1)
    else:                                                           # wash, watercolor
        low = sm(rng.random((h, w)), 41)
        body = np.clip(0.8 + (low - 0.5) * 1.5, 0.5, 1)
        rim = np.exp(-((np.abs(y) - 0.85) ** 2) / 0.008) * (0.5 if kind == "watercolor" else 0.2)
        a = np.clip(np.clip(1 - np.abs(y) ** 3, 0, 1) * body + rim, 0, 1)
    out = np.ones((h, w, 4), dtype=np.float32)
    out[..., 0], out[..., 1], out[..., 2] = rgb
    out[..., 3] = np.clip(a, 0, 1)
    return out


def quantize_colors(colors, n=24, seed=1):
    """Maps many colours to at most n shared ones (k-means). Returns a list of "#rrggbb", one per input."""
    arr = np.asarray([_hex(c) for c in colors], dtype=np.float32)
    uniq = np.unique(np.round(arr * 255).astype(int), axis=0)
    if len(uniq) <= n:
        return [color(tuple(c)) for c in arr]
    rng = np.random.default_rng(seed)
    cent = arr[rng.choice(len(arr), n, replace=False)]
    for _ in range(10):
        lab = ((arr[:, None, :] - cent[None, :, :]) ** 2).sum(-1).argmin(1)
        for k in range(n):
            m = arr[lab == k]
            if len(m):
                cent[k] = m.mean(0)
    return [color(tuple(cent[k])) for k in lab]


# --------------------------------------------------------------------------- stroke planning (no Blender)

def taper_profile(n, taper=0.3, start=None, end=None, floor=0.12):
    """Pressure along a stroke: thin ends, full middle."""
    if n <= 1:
        return np.ones(max(n, 1))
    t = np.linspace(0, 1, n)
    s = taper if start is None else start
    e = taper if end is None else end
    p = np.ones(n)
    if s > 0:
        p = np.minimum(p, np.clip(t / s, 0, 1) ** 0.7)
    if e > 0:
        p = np.minimum(p, np.clip((1 - t) / e, 0, 1) ** 0.7)
    return np.maximum(p, floor)


def smooth_path(points, samples=6, closed=False):
    """Catmull-Rom through points (for hand-placed control points)."""
    p = np.asarray(points, dtype=float)
    if len(p) < 3:
        return p
    if closed:
        p = np.vstack([p[-1], p, p[0], p[1]])
    else:
        p = np.vstack([p[0], p, p[-1]])
    out = []
    for i in range(1, len(p) - 2):
        p0, p1, p2, p3 = p[i - 1], p[i], p[i + 1], p[i + 2]
        for t in np.linspace(0, 1, samples, endpoint=False):
            t2, t3 = t * t, t * t * t
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    out.append(p[-2])
    return np.asarray(out)


def jitter_path(points, amount, seed=None):
    """Hand wobble: shifts points by up to `amount` pixels."""
    if amount <= 0:
        return np.asarray(points, dtype=float)
    rng = np.random.default_rng(seed)
    p = np.asarray(points, dtype=float)
    noise = rng.normal(0, amount, p.shape)
    k = np.ones(5) / 5
    for c in range(2):
        noise[:, c] = np.convolve(noise[:, c], k, "same")
    return p + noise


def gradients(gray):
    """Sobel gradients of a 2D array (y down)."""
    g = np.pad(gray, 1, mode="edge")
    gx = (g[:-2, 2:] + 2 * g[1:-1, 2:] + g[2:, 2:]) - (g[:-2, :-2] + 2 * g[1:-1, :-2] + g[2:, :-2])
    gy = (g[2:, :-2] + 2 * g[2:, 1:-1] + g[2:, 2:]) - (g[:-2, :-2] + 2 * g[:-2, 1:-1] + g[:-2, 2:])
    return gx, gy


def blur(arr, r):
    """Box blur (separable) of a 2D or 3D array."""
    r = int(max(r, 0))
    if r == 0:
        return arr
    k = np.ones(2 * r + 1) / (2 * r + 1)
    out = arr.astype(np.float32)
    for axis in (0, 1):
        out = np.apply_along_axis(lambda v: np.convolve(np.pad(v, r, mode="edge"), k, "valid"), axis, out)
    return out


def plan_paint(pixels, sizes, density=1.0, length=6, follow=True, detail=0.5, seed=1, max_strokes=20000):
    """Plans brush strokes that repaint an image, big strokes first then finer ones (Hertzmann-style).

    pixels: H×W×3 (0…1, y down). sizes: brush sizes in pixels of `pixels`, one per layer, biggest first.
    Returns a list of dicts: layer, points (N×2 in pixel coords), size, color (r, g, b)."""
    img = np.asarray(pixels, dtype=np.float32)[..., :3]
    H, W = img.shape[:2]
    rng = random.Random(seed)
    strokes = []
    canvas = np.full_like(img, np.nan)
    for li, size in enumerate(sizes):
        size = max(float(size), 1.0)
        ref = blur(img, int(size / 3))
        gray = ref @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
        gx, gy = gradients(gray)
        mag = np.hypot(gx, gy)
        step = max(1.0, size * 0.75 / max(density, 0.05))
        pts = [(x + rng.uniform(-step / 2, step / 2), y + rng.uniform(-step / 2, step / 2))
               for y in np.arange(step / 2, H, step) for x in np.arange(step / 2, W, step)]
        rng.shuffle(pts)
        # Later layers only paint where the canvas still differs from the picture (the detail).
        thresh = 0.0 if li == 0 else (0.25 - 0.2 * detail) * (1 if li == 1 else 0.8)
        for (x, y) in pts:
            xi, yi = int(min(max(x, 0), W - 1)), int(min(max(y, 0), H - 1))
            col = ref[yi, xi]
            if li > 0:
                cur = canvas[yi, xi]
                if not np.isnan(cur[0]) and np.abs(cur - col).sum() < thresh:
                    continue
            path = [(x, y)]
            if follow and length > 1:
                for direction in (1, -1):
                    px, py = x, y
                    dx = dy = None
                    for _ in range(int(length) // 2):
                        ix, iy = int(min(max(px, 0), W - 1)), int(min(max(py, 0), H - 1))
                        g = mag[iy, ix]
                        if g < 1e-4:
                            break
                        # Strokes run along edges: perpendicular to the gradient.
                        tx, ty = -gy[iy, ix] / g, gx[iy, ix] / g
                        if dx is not None and tx * dx + ty * dy < 0:
                            tx, ty = -tx, -ty
                        dx, dy = tx, ty
                        px, py = px + direction * dx * size * 0.6, py + direction * dy * size * 0.6
                        if not (0 <= px < W and 0 <= py < H):
                            break
                        if np.abs(ref[int(py), int(px)] - col).sum() > 0.35:
                            break
                        path.append((px, py)) if direction == 1 else path.insert(0, (px, py))
            if len(path) == 1:                                       # a dab
                a = rng.uniform(0, math.pi)
                path = [(x - math.cos(a) * size * 0.3, y - math.sin(a) * size * 0.3),
                        (x + math.cos(a) * size * 0.3, y + math.sin(a) * size * 0.3)]
            path = np.asarray(path)
            strokes.append({"layer": li, "points": path, "size": size, "color": tuple(float(v) for v in col)})
            r = max(int(size / 2), 1)
            for (sx, sy) in path:
                y0, y1 = max(int(sy) - r, 0), min(int(sy) + r + 1, H)
                x0, x1 = max(int(sx) - r, 0), min(int(sx) + r + 1, W)
                canvas[y0:y1, x0:x1] = col
            if len(strokes) >= max_strokes:
                return strokes
    return strokes


def plan_ink(pixels, threshold=0.3, min_length=10, spacing=3, max_lines=2500):
    """Plans ink lines along the strong edges of an image. Returns a list of N×2 point arrays."""
    img = np.asarray(pixels, dtype=np.float32)[..., :3]
    gray = blur(img @ np.array([0.299, 0.587, 0.114], dtype=np.float32), 1)
    gx, gy = gradients(gray)
    mag = np.hypot(gx, gy)
    mag = mag / (mag.max() + 1e-6)
    H, W = mag.shape
    used = np.zeros_like(mag, dtype=bool)
    seeds = np.argwhere(mag > threshold)
    order = np.argsort(-mag[seeds[:, 0], seeds[:, 1]])
    lines = []
    for idx in order[::max(1, spacing // 2)]:
        y, x = seeds[idx]
        if used[y, x]:
            continue
        path = [(float(x), float(y))]
        for direction in (1, -1):
            px, py = float(x), float(y)
            pdx = pdy = None
            for _ in range(200):
                ix, iy = int(px), int(py)
                g = mag[iy, ix]
                if g < threshold * 0.6:
                    break
                tx, ty = -gy[iy, ix], gx[iy, ix]
                n = math.hypot(tx, ty) or 1.0
                tx, ty = tx / n, ty / n
                if pdx is not None and tx * pdx + ty * pdy < 0:
                    tx, ty = -tx, -ty
                pdx, pdy = tx, ty
                px, py = px + direction * tx * spacing, py + direction * ty * spacing
                if not (1 <= px < W - 1 and 1 <= py < H - 1) or used[int(py), int(px)]:
                    break
                path.append((px, py)) if direction == 1 else path.insert(0, (px, py))
        if len(path) >= min_length:
            for (sx, sy) in path:
                used[max(int(sy) - spacing, 0):int(sy) + spacing + 1, max(int(sx) - spacing, 0):int(sx) + spacing + 1] = True
            lines.append(np.asarray(path))
            if len(lines) >= max_lines:
                break
    return lines


# --------------------------------------------------------------------------- the Blender side

class _State:
    width = 1920
    height = 1080
    world_w = 10.0
    fps = 24
    frames = 96
    ob = None
    layer = None
    drawing = None
    brushes = {}
    picture = None
    draw_on = None


S = _State()
IMAGE = ""          # the picture chosen in Script Lab (a file path), set by PRISM


def _need_blender():
    if bpy is None:
        raise RuntimeError("This part of prism_gp runs inside Blender (Script Lab).")


def canvas(width=None, height=None, background="#ffffff", seconds=4.0, fps=24, picture=None):
    """Starts a fresh drawing: size in pixels, background colour, length. With a picture (or the one
    chosen in Script Lab) and no size, the canvas takes the picture's shape (long side 1920)."""
    _need_blender()
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    pic_path = picture if picture is not None else IMAGE
    if (width is None or height is None) and pic_path:
        pic = load_picture(pic_path)
        ph, pw = pic.shape[:2]
        long = 1920
        width, height = (long, round(long * ph / pw)) if pw >= ph else (round(long * pw / ph), long)
    width, height = int(width or 1920), int(height or 1080)
    width += width % 2
    height += height % 2
    S.width, S.height, S.fps = width, height, int(fps)
    S.frames = max(1, int(round(seconds * fps)))
    S.world_w = 10.0
    S.brushes = {}
    S.draw_on = None
    sc = bpy.context.scene
    sc.render.resolution_x, sc.render.resolution_y = width, height
    sc.render.resolution_percentage = 100
    sc.render.fps = S.fps
    sc.frame_start, sc.frame_end = 1, S.frames
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            sc.render.engine = eng
            break
        except Exception:
            pass
    try:
        sc.view_settings.view_transform = "Standard"
    except Exception:
        pass
    try:
        sc.grease_pencil_settings.antialias_threshold = 1.0
    except Exception:
        pass
    world = sc.world or bpy.data.worlds.new("Prism World")
    sc.world = world
    try:
        world.use_nodes = True
        world.node_tree.nodes["Background"].inputs["Color"].default_value = (*to_linear(background), 1)
    except Exception:
        world.color = to_linear(background)
    # Orthographic camera looking at the XZ plane.
    cd = bpy.data.cameras.new("Prism Camera")
    cd.type = "ORTHO"
    cd.ortho_scale = S.world_w * max(1.0, height / width)
    cam = bpy.data.objects.new("Prism Camera", cd)
    sc.collection.objects.link(cam)
    cam.location = (0, -10, 0)
    cam.rotation_euler = (math.pi / 2, 0, 0)
    sc.camera = cam
    gp = bpy.data.grease_pencils.new("Prism Drawing")
    S.ob = bpy.data.objects.new("Prism Drawing", gp)
    sc.collection.objects.link(S.ob)
    layer("Paint")
    return S.ob


def _world_h():
    return S.world_w * S.height / S.width


def _to_world(points):
    p = np.asarray(points, dtype=float).reshape(-1, 2)
    wx = (p[:, 0] / S.width - 0.5) * S.world_w
    wz = (0.5 - p[:, 1] / S.height) * _world_h()
    out = np.zeros((len(p), 3), dtype=np.float32)
    out[:, 0], out[:, 2] = wx, wz
    return out


def _px():
    return S.world_w / S.width


def layer(name):
    """Draw on a layer (created on top if new). Later layers draw over earlier ones."""
    _need_blender()
    gp = S.ob.data
    lay = gp.layers.get(name)
    if lay is None:
        lay = gp.layers.new(name, set_active=False)
        lay.use_lights = False                 # exact colours (lit layers render dark)
        lay.frames.new(1)
    S.layer = lay
    S.drawing = lay.frames[0].drawing
    return lay


def brush(name, kind="ink", color="#111111", size=6, opacity=None, taper=None, jitter=0.0,
          texture=None, softness=None, spacing=None):
    """Makes a brush: a Grease Pencil material plus how pressure shapes the stroke.

    kind: ink, pen, marker, pencil, charcoal, chalk, bristle, oil, dry, wash, watercolor, airbrush, dots, squares.
    texture: one of TEXTURES or an image path (overrides the kind's texture)."""
    _need_blender()
    tex, pressure, k_taper, k_opa, k_soft, mode = KINDS.get(kind, KINDS["ink"])
    tex = texture or tex
    m = bpy.data.materials.new("Brush " + name)
    bpy.data.materials.create_gpencil_data(m)
    g = m.grease_pencil
    g.color = (1, 1, 1, 1)                     # each point carries its colour (vertex colour)
    g.show_stroke = True
    g.show_fill = False
    for prop, val in (("mode", mode), ("stroke_style", "SOLID")):
        try:
            setattr(g, prop, val)
        except Exception:
            pass
    if mode != "LINE" and spacing:
        for prop in ("dot_spacing", "spacing"):
            try:
                setattr(g, prop, float(spacing))
            except Exception:
                pass
    S.ob.data.materials.append(m)
    b = {"name": name, "kind": kind, "index": len(S.ob.data.materials) - 1, "color": color, "size": float(size),
         "texture": tex, "material": m, "by_color": {},
         "opacity": k_opa if opacity is None else float(opacity), "taper": k_taper if taper is None else float(taper),
         "pressure": pressure, "jitter": float(jitter), "softness": k_soft if softness is None else float(softness)}
    S.brushes[name] = b
    return b


def _material_for(b, col):
    """The material slot for a stroke of brush b in colour col. Solid brushes share one material and
    take the colour per point; textured brushes get a tinted copy per colour (Blender colours textured
    strokes from the texture)."""
    if b["texture"] == "solid":
        return b["index"]
    key = color(col)
    if key in b["by_color"]:
        return b["by_color"][key]
    m = b["material"].copy()
    m.name = "Brush %s %s" % (b["name"], key)
    img = _texture_image(b["texture"], _hex(key))
    g = m.grease_pencil
    try:
        if img is not None:
            g.stroke_style = "TEXTURE"
            g.stroke_image = img
            g.mix_stroke_factor = 0.0
        g.color = (*to_linear(key), 1.0)
    except Exception as e:
        print("PRISM-NOTE: texture not applied:", e)
    S.ob.data.materials.append(m)
    b["by_color"][key] = len(S.ob.data.materials) - 1
    return b["by_color"][key]


def _texture_image(tex, rgb=(1.0, 1.0, 1.0)):
    if isinstance(tex, str) and tex not in TEXTURES:
        try:
            return bpy.data.images.load(tex, check_existing=True)
        except Exception:
            return None
    px = texture_pixels(tex, rgb=rgb)
    h, w = px.shape[:2]
    img = bpy.data.images.new("Brush texture %s %s" % (tex, color(rgb)), w, h, alpha=True)
    img.pixels.foreach_set(px[::-1].reshape(-1).astype(np.float32))     # Blender rows run bottom-up
    img.pack()
    return img


def _attr(d, name, kind, domain, default, n_total):
    a = d.attributes.get(name)
    if a is None:
        # New attributes start at zero for every point; set defaults first (a zero radius hides strokes).
        a = d.attributes.new(name, kind, domain)
        key = "color" if kind == "FLOAT_COLOR" else "value"
        width = 4 if kind == "FLOAT_COLOR" else 1
        a.data.foreach_set(key, np.tile(np.asarray(default, np.float32), n_total).reshape(-1))
    return a


def strokes(specs):
    """Adds many strokes at once. Each spec: brush, points (pixels), and optional size, color,
    opacity, pressure (list), fill (True for a filled closed shape), close (True)."""
    _need_blender()
    specs = [dict(s) for s in specs if len(s["points"]) >= 1]
    if not specs:
        return
    # Textured brushes need a material per colour: share at most 24 colours per brush.
    for name in {s["brush"]["name"] for s in specs if s["brush"]["texture"] != "solid"}:
        group = [s for s in specs if s["brush"]["name"] == name]
        q = quantize_colors([s.get("color", s["brush"]["color"]) for s in group], n=24)
        for s, c in zip(group, q):
            s["color"] = c
    d = S.drawing
    n0 = len(d.attributes["position"].data) if "position" in d.attributes else 0
    c0 = len(d.strokes)
    pos, rad, opa, col = [], [], [], []
    sizes = []
    for s in specs:
        b = s["brush"]
        pts = np.asarray(s["points"], dtype=float).reshape(-1, 2)
        if b["jitter"] > 0 and not s.get("fill"):
            pts = jitter_path(pts, b["jitter"])
        if len(pts) == 1:
            pts = np.vstack([pts, pts + 0.01])
        n = len(pts)
        sizes.append(n)
        pr = s.get("pressure")
        pr = taper_profile(n, b["taper"]) if pr is None else np.resize(np.asarray(pr, float), n)
        size = float(s.get("size", b["size"]))
        r = np.full(n, size / 2 * _px())
        o = np.full(n, float(s.get("opacity", b["opacity"])))
        if b["pressure"] in ("radius", "both"):
            r = r * pr
        if b["pressure"] in ("opacity", "both"):
            o = o * pr
        pos.append(_to_world(pts))
        rad.append(r)
        opa.append(o)
        c = to_linear(s.get("color", b["color"]))
        # Solid brushes take colour per point; textured ones from their tinted material (alpha 0 = no override).
        col.append(np.tile((*c, 1.0 if b["texture"] == "solid" else 0.0), (n, 1)))
    d.add_strokes(sizes)
    total = n0 + sum(sizes)
    P = np.concatenate(pos).reshape(-1)
    allpos = np.zeros(total * 3, np.float32)
    if n0:
        d.attributes["position"].data.foreach_get("vector", allpos)
    allpos[n0 * 3:] = P
    d.attributes["position"].data.foreach_set("vector", allpos)
    for name, kind, default, vals, width in (("radius", "FLOAT", 0.01, rad, 1), ("opacity", "FLOAT", 1.0, opa, 1),
                                             ("vertex_color", "FLOAT_COLOR", (0, 0, 0, 0), col, 4)):
        a = _attr(d, name, kind, "POINT", default, total)
        key = "color" if kind == "FLOAT_COLOR" else "value"
        buf = np.zeros(total * width, np.float32)
        a.data.foreach_get(key, buf)
        buf[n0 * width:] = np.concatenate(vals).reshape(-1)
        a.data.foreach_set(key, buf)
    for i, s in enumerate(specs):
        st = d.strokes[c0 + i]
        st.material_index = _material_for(s["brush"], s.get("color", s["brush"]["color"]))
        closed = bool(s.get("close") or s.get("fill"))
        st.cyclic = closed
        if s.get("fill"):
            st.fill_id = int(s.get("fill_id", c0 + i + 1))
            try:
                st.fill_color = (*to_linear(s.get("color", s["brush"]["color"])), 1.0)
            except Exception:
                pass
            st.hide_stroke = not s.get("outline", False)
        soft = s["brush"]["softness"]
        if soft:
            try:
                st.softness = soft
            except Exception:
                pass
    d.tag_positions_changed()


def stroke(b, points, **kw):
    """One stroke through points (pixels). smooth=True rounds the path through them."""
    pts = smooth_path(points) if kw.pop("smooth", False) else points
    strokes([dict(brush=b, points=pts, **kw)])


def line(b, a, c, **kw):
    n = max(2, int(math.dist(a, c) / 6))
    stroke(b, np.linspace(a, c, n), **kw)


def circle(b, center, r, fill=False, **kw):
    t = np.linspace(0, 2 * math.pi, 64, endpoint=not fill and not kw.get("close"))
    pts = np.c_[center[0] + r * np.cos(t), center[1] + r * np.sin(t)]
    stroke(b, pts, fill=fill, **kw)


def ellipse(b, center, rx, ry, fill=False, **kw):
    t = np.linspace(0, 2 * math.pi, 64, endpoint=not fill)
    stroke(b, np.c_[center[0] + rx * np.cos(t), center[1] + ry * np.sin(t)], fill=fill, **kw)


def rect(b, x, y, w, h, fill=False, **kw):
    pts = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
    if not fill:
        pts = pts + [(x, y)]
    dense = np.vstack([np.linspace(pts[i], pts[i + 1], 12) for i in range(len(pts) - 1)])
    stroke(b, dense, fill=fill, **kw)


def arc(b, center, r, start_deg, end_deg, **kw):
    t = np.radians(np.linspace(start_deg, end_deg, 48))
    stroke(b, np.c_[center[0] + r * np.cos(t), center[1] - r * np.sin(t)], **kw)


def polygon(b, points, fill=True, **kw):
    stroke(b, points, fill=fill, **kw)


# --------------------------------------------------------------------------- pictures

def load_picture(path=None, max_side=480):
    """The picture as an H×W×3 sRGB array (0…1, y down), shrunk so the long side is max_side."""
    _need_blender()
    path = path or IMAGE
    if not path:
        raise ValueError("Choose a picture in Script Lab (or pass a file path).")
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    s = min(1.0, max_side / max(w, h))
    if s < 1.0:
        img.scale(max(1, int(w * s)), max(1, int(h * s)))
        w, h = img.size
    px = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(px)
    arr = px.reshape(h, w, 4)[::-1, :, :3]
    try:
        cs = img.colorspace_settings.name
        if cs not in ("sRGB", "Non-Color", "Raw") and img.is_float:   # float images hold linear values
            arr = np.where(arr <= 0.0031308, arr * 12.92, 1.055 * np.power(np.clip(arr, 0, None), 1 / 2.4) - 0.055)
    except Exception:
        pass
    bpy.data.images.remove(img)
    return np.clip(arr, 0, 1)


def picture_palette(n=6, path=None):
    """The picture's n main colours, as hex strings."""
    return palette_from(load_picture(path, 160), n)


def paint(brushes, picture=None, layers=None, sizes=None, density=1.0, length=8, detail=0.5, seed=1,
          max_strokes=20000, layer_name="Paint"):
    """Repaints the picture with brush strokes, broad strokes first, finer ones where detail is needed.

    brushes: one brush, or a list (one per pass, biggest first). sizes: stroke sizes in canvas pixels per
    pass (default: each brush's size). length: how far strokes travel along the forms (in brush widths)."""
    pic = load_picture(picture)
    blist = brushes if isinstance(brushes, (list, tuple)) else [brushes]
    passes = layers or len(blist)
    scale = S.width / pic.shape[1]
    if sizes is None:
        sizes = [blist[min(i, len(blist) - 1)]["size"] * (0.55 ** max(0, i - len(blist) + 1)) for i in range(passes)]
    plan = plan_paint(pic, [s / scale for s in sizes], density=density, length=length, detail=detail,
                      seed=seed, max_strokes=max_strokes)
    for i in range(passes):
        layer(f"{layer_name} {i + 1}")
        b = blist[min(i, len(blist) - 1)]
        strokes([dict(brush=b, points=s["points"] * scale, size=s["size"] * scale, color=s["color"])
                 for s in plan if s["layer"] == i])
    print("PRISM: painted %d strokes in %d passes." % (len(plan), passes))
    return len(plan)


def ink(b, picture=None, threshold=0.3, detail=0.5, layer_name="Ink"):
    """Ink lines along the picture's strong edges, on their own layer on top."""
    pic = load_picture(picture, max_side=int(320 + 480 * detail))
    scale = S.width / pic.shape[1]
    lines = plan_ink(pic, threshold=threshold, min_length=int(14 - 8 * detail))
    layer(layer_name)
    strokes([dict(brush=b, points=smooth_path(l[::2], samples=3) * scale) for l in lines])
    print("PRISM: inked %d lines." % len(lines))
    return len(lines)


# --------------------------------------------------------------------------- motion and effects

def draw_on(seconds=None, start=0.0, order="layers"):
    """Animates the drawing appearing stroke by stroke. order='layers' paints layer after layer
    (washes first, ink last); 'together' draws all layers at once."""
    _need_blender()
    total = int(round((seconds or (S.frames / S.fps * 0.85)) * S.fps))
    lays = [l for l in S.ob.data.layers]
    each = total if order == "together" else max(1, total // max(len(lays), 1))
    for i, lay in enumerate(lays):
        m = S.ob.modifiers.new("Draw On " + lay.name, "GREASE_PENCIL_BUILD")
        for prop, val in (("mode", "SEQUENTIAL"), ("transition", "GROW"), ("time_mode", "FRAMES"),
                          ("start_delay", float(start * S.fps + (0 if order == "together" else i * each))),
                          ("length", float(each)), ("tree_node_filter", lay.name)):
            try:
                setattr(m, prop, val)
            except Exception as e:
                print("PRISM-NOTE: Build", prop, e)


def boil(amount=1.0, step=3):
    """Hand-drawn line boil (the lines wobble every few frames)."""
    m = S.ob.modifiers.new("Boil", "GREASE_PENCIL_NOISE")
    for prop, val in (("factor", 0.4 * amount), ("factor_thickness", 0.2 * amount), ("noise_scale", 0.3),
                      ("use_random", True), ("step", int(step))):
        try:
            setattr(m, prop, val)
        except Exception:
            pass


def glow(color="#ffd27a", radius=40, threshold=0.1):
    """A soft glow around bright strokes."""
    fx = S.ob.shader_effects.new("Glow", "FX_GLOW")
    for prop, val in (("mode", "LUMINANCE"), ("threshold", threshold), ("size", (radius, radius)),
                      ("glow_color", to_linear(color)), ("use_glow_under", False)):
        try:
            setattr(fx, prop, val)
        except Exception:
            pass


def shadow(offset=(8, -8), color="#000000", opacity=0.4, blur=8):
    fx = S.ob.shader_effects.new("Shadow", "FX_SHADOW")
    for prop, val in (("offset", offset), ("shadow_color", (*to_linear(color), opacity)), ("blur", (blur, blur))):
        try:
            setattr(fx, prop, val)
        except Exception:
            pass


def effect(kind, **props):
    """Any Grease Pencil visual effect: 'blur', 'colorize', 'flip', 'glow', 'pixel', 'rim', 'shadow', 'swirl', 'wave'."""
    fx = S.ob.shader_effects.new(kind.title(), "FX_" + kind.upper())
    for k, v in props.items():
        try:
            setattr(fx, k, v)
        except Exception as e:
            print("PRISM-NOTE: effect", k, e)
    return fx


def modifier(kind, **props):
    """Any Grease Pencil modifier, e.g. modifier('noise', factor=0.5) or modifier('thickness', thickness_factor=2)."""
    m = S.ob.modifiers.new(kind.title(), "GREASE_PENCIL_" + kind.upper())
    for k, v in props.items():
        try:
            setattr(m, k, v)
        except Exception as e:
            print("PRISM-NOTE: modifier", k, e)
    return m


__all__ = ["canvas", "layer", "brush", "stroke", "strokes", "line", "circle", "ellipse", "rect", "arc", "polygon",
           "color", "mix", "lighten", "darken", "hsv", "gradient", "palette_from", "picture_palette", "load_picture",
           "paint", "ink", "draw_on", "boil", "glow", "shadow", "effect", "modifier", "smooth_path", "taper_profile",
           "IMAGE", "KINDS", "TEXTURES", "S", "np", "math", "random", "plan_paint", "plan_ink", "jitter_path", "to_linear", "quantize_colors"]
