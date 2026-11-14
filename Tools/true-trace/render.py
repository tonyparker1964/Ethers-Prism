import sys, time, numpy as np
from PIL import Image, ImageDraw
sys.path.insert(0, '/tmp/tt')
from core import trace, resize

def load(p):
    return np.asarray(Image.open(p).convert('RGB'), dtype=np.float32) / 255

recipe_ink_dark = 0.65
RECIPE = {}
def draw(res, scale=3, ink=(0.08, 0.06, 0.1), ink_w=1.4, bg=(0.05, 0.05, 0.07)):
    W, H = res['w'] * scale, res['h'] * scale
    im = Image.new('RGB', (W, H), tuple(int(c * 255) for c in bg))
    d = ImageDraw.Draw(im)
    dim = RECIPE.get('fill_dim', 1.0)
    for f in res['fills']:
        d.polygon([(x * scale, y * scale) for x, y in f['pts']], fill=tuple(int(c * 255 * dim) for c in f['col']))
    ov = Image.new('RGBA', (W, H), (0, 0, 0, 0)); od = ImageDraw.Draw(ov)
    for l in res['lines']:
        p = l['pts'] + [l['pts'][0]]; st = l['strength'] + [l['strength'][0]]
        dark = recipe_ink_dark
        if RECIPE.get('ink', 0) <= 0: continue
        col = tuple(int(c * 255 * (1 - dark) + ink[i] * 255 * dark) for i, c in enumerate(l['col'])) if dark >= 0 else tuple(int(min(1, c * (1 - dark) + 0.15) * 255) for c in l['col'])
        for i in range(len(p) - 1):
            a = (st[i] + st[i + 1]) / 2
            if a > 0.02:
                od.line([(p[i][0] * scale, p[i][1] * scale), (p[i + 1][0] * scale, p[i + 1][1] * scale)], fill=col + (int(255 * a),), width=max(1, int(ink_w * scale)))
    im = Image.alpha_composite(im.convert('RGBA'), ov).convert('RGB')
    return im.resize((res['w'] * 2, res['h'] * 2), Image.LANCZOS)

if __name__ == '__main__':
    src, out = sys.argv[1], sys.argv[2]
    recipe = eval(sys.argv[3]) if len(sys.argv) > 3 else {}
    rgb = load(src)
    H, W = rgb.shape[:2]; s = recipe.get('work', 640) / max(W, H)
    small = resize(rgb, int(W * s), int(H * s))
    t = time.time(); res = trace(small, recipe); dt = time.time() - t
    print(f"{out}: {len(res['fills'])} fills, {len(res['lines'])} lines, {dt:.1f}s")
    globals()['RECIPE'] = recipe
    globals()['recipe_ink_dark'] = recipe.get('ink_dark', 0.65)
    draw(res, ink_w=recipe.get('ink_w', 1.2)).save(out)
