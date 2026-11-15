import sys, numpy as np
from PIL import Image
sys.path.insert(0, __import__('os').path.dirname(__file__))
from core import *
src = np.asarray(Image.open(sys.argv[1]).convert('RGB'), dtype=np.float32)/255
H,W = src.shape[:2]; s = 256/max(W,H)
rgb = resize(src, int(W*s), int(H*s))
m, cut = subject_mask(rgb)
h, R = height_field(rgb, m, inflate=1.0 if cut else 0.25, detail=0.25 if cut else 0.9)
h = h * 0.35 * R if cut else h * 40    # height in pixels, ~35% of the subject's half-width
gy, gx = np.gradient(h)
n = np.dstack([-gx, -gy, np.ones_like(h)]); n /= np.linalg.norm(n, axis=2, keepdims=True)
L = np.array([-0.5, -0.6, 0.62]); L /= np.linalg.norm(L)
shade = np.clip((n*L).sum(2), 0, 1)*0.85 + 0.15
img = (rgb*0.8+0.2*np.array([0.85,0.6,0.45]))*shade[...,None]
img = np.where(m[...,None], img, 0.12)
Image.fromarray((img.clip(0,1)*255).astype(np.uint8)).resize((W*2*256//max(W,H)//1, H*2*256//max(W,H)//1)).save(sys.argv[2])
print('mask coverage', round(m.mean(),2), 'max dist', round(R,1))
