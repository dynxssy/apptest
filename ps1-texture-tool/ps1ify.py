#!/usr/bin/env python3
"""Batch-convert flat pixel-art character textures into grittier, more
"realistic" PS1-era human textures.

Pipeline per image:
  1. detect the pixel-art block size and recover the native-resolution art
  2. smooth-upscale it to a working resolution
  3. classify every pixel softly as skin / hair (dark) / cloth
  4. add procedural, tileable surface detail per material
     (skin blotches + pores, hair strands, cloth weave + folds)
  5. bake fake volume: large-radius local contrast + edge occlusion
  6. PS1 output stage: downsample to texture res, 15-bit colour with the
     real PS1 4x4 ordered-dither matrix, optional CLUT palette (4/8-bit),
     then nearest-neighbour scale back so the file is a drop-in replacement

Only needs numpy + Pillow.  Usage:
  python ps1ify.py input_dir output_dir [options]
  python ps1ify.py face.png out/ --res 128 --colors 256
"""
import argparse
import hashlib
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# PlayStation GPU dither matrix (added to 8-bit colour before truncation to 5 bits)
PS1_DITHER = np.array([[-4, 0, -3, 1],
                       [2, -2, 3, -1],
                       [-3, 1, -4, 0],
                       [3, -1, 2, -2]], dtype=np.float32)

IMAGE_EXTS = {".png", ".bmp", ".tga", ".jpg", ".jpeg", ".gif", ".webp"}


# ----------------------------------------------------------------- helpers

def blur(a, sigma):
    """Separable gaussian blur with wrap-around edges (textures tile)."""
    if sigma <= 0:
        return a
    r = max(1, int(sigma * 3))
    x = np.arange(-r, r + 1, dtype=np.float32)
    k = np.exp(-(x * x) / (2 * sigma * sigma))
    k /= k.sum()
    out = a
    for axis in (0, 1):
        acc = np.zeros_like(out)
        for i, w in enumerate(k):
            acc += w * np.roll(out, i - r, axis=axis)
        out = acc
    return out


def resize_f(a, w, h, resample=Image.BICUBIC):
    """Resize a float32 2D array via Pillow's 'F' mode."""
    return np.array(Image.fromarray(a.astype(np.float32), "F").resize((w, h), resample))


def resize_rgb(a, w, h, resample=Image.BICUBIC):
    return np.stack([resize_f(a[..., c], w, h, resample) for c in range(3)], -1)


def tile_noise(rng, h, w, cell_x, cell_y=None):
    """Tileable smooth value noise in [-1, 1].  cell_x/cell_y = feature size in px."""
    cell_y = cell_y or cell_x
    gx, gy = max(1, round(w / cell_x)), max(1, round(h / cell_y))
    g = rng.random((gy, gx)).astype(np.float32)
    # upscale a 3x3 tiling and keep the centre so the result wraps seamlessly
    n = resize_f(np.tile(g, (3, 3)), w * 3, h * 3)[h:2 * h, w:2 * w]
    n -= n.mean()
    return n / (np.abs(n).max() + 1e-6)


def fbm(rng, h, w, base, octaves=4, stretch=(1.0, 1.0)):
    out = np.zeros((h, w), np.float32)
    amp, tot, cell = 1.0, 0.0, float(base)
    for _ in range(octaves):
        out += amp * tile_noise(rng, h, w, max(1, cell * stretch[0]), max(1, cell * stretch[1]))
        tot += amp
        amp *= 0.5
        cell /= 2
    return out / tot


def rgb_to_hsv(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx, mn = a.max(-1), a.min(-1)
    d = mx - mn + 1e-6
    h = np.where(mx == r, ((g - b) / d) % 6, np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4)) / 6
    s = np.where(mx > 0, (mx - mn) / (mx + 1e-6), 0)
    return h, s, mx


def detect_block(a, max_k=8):
    """Largest block size k for which the image is (almost) made of kxk blocks."""
    h, w = a.shape[:2]
    best = 1
    for k in range(2, max_k + 1):
        if h % k or w % k:
            continue
        blocks = a.reshape(h // k, k, w // k, k, 3)
        mean = blocks.mean(axis=(1, 3), keepdims=True)
        if np.abs(blocks - mean).mean() < 2.0:
            best = k
    return best


# ----------------------------------------------------------------- pipeline

def material_masks(rgb, skin_hue=(0.0, 0.12)):
    """Soft masks (skin, hair, cloth) summing to 1. rgb in 0..1."""
    h, s, v = rgb_to_hsv(rgb)
    lo, hi = skin_hue
    hue_ok = np.clip(1 - np.maximum(lo - h, h - hi) / 0.03, 0, 1)
    hue_ok = np.maximum(hue_ok, np.clip(1 - (1 - h) / 0.03, 0, 1))  # reds wrapping past 1.0
    skin = hue_ok * np.clip((s - 0.12) / 0.1, 0, 1) * np.clip((v - 0.25) / 0.1, 0, 1)
    hair = np.clip((0.2 - v) / 0.1, 0, 1) * (1 - skin)
    cloth = np.clip(1 - skin - hair, 0, 1)
    tot = skin + hair + cloth + 1e-6
    return [blur(m / tot, 1.2) for m in (skin, hair, cloth)]


def add_detail(rgb, masks, rng, strength):
    H, W = rgb.shape[:2]
    skin, hair, cloth = masks
    lum = rgb.mean(-1)
    out = rgb.copy()
    u = W / 256.0  # scale noise with working resolution

    # --- skin: uneven tone, redness, pores, a bit of grime
    blotch = fbm(rng, H, W, 40 * u, 3)
    redness = fbm(rng, H, W, 24 * u, 3)
    pores = tile_noise(rng, H, W, 1.5 * u) * 0.6 + tile_noise(rng, H, W, 3 * u) * 0.4
    sk = np.zeros_like(rgb)
    sk += (blotch * 0.06)[..., None]
    sk += (redness * 0.035)[..., None] * np.array([1.0, -0.4, -0.6], np.float32)
    sk += (pores * 0.035)[..., None]
    out += sk * skin[..., None] * strength

    # --- hair / dark areas: vertical strands + clumps
    strands = fbm(rng, H, W, 6 * u, 3, stretch=(0.25, 6.0))
    clumps = fbm(rng, H, W, 32 * u, 2)
    hr = (strands * 0.07 + clumps * 0.04)[..., None] * (0.4 + lum[..., None])
    out += hr * hair[..., None] * strength * 1.4

    # --- cloth: weave, fibre noise, soft folds, wear on light areas
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    period = max(2.0, 2.0 * u)
    weave = np.sin(xx * np.pi / period) * np.sin(yy * np.pi / period)
    fibre = tile_noise(rng, H, W, 1.0 * u, 4 * u)
    folds = fbm(rng, H, W, 48 * u, 3, stretch=(0.5, 2.0))
    wear = np.clip(fbm(rng, H, W, 20 * u, 4), 0, None)
    cl = weave * 0.02 + fibre * 0.03 + folds * 0.08 + wear * 0.05 * lum
    out += cl[..., None] * cloth[..., None] * strength

    return out


def bake_volume(rgb, strength, u):
    """Fake baked lighting: large-scale local contrast + occlusion in creases."""
    lum = rgb.mean(-1)
    big = blur(lum, 10 * u)
    local = lum - big                      # >0 raised, <0 recessed
    rgb = rgb + (local * 0.2 * strength)[..., None]
    # soft occlusion: light pixels next to dark areas (under hair, around
    # eyes/mouth, cloth seams) receive a little falloff shadow
    occ = np.clip(blur(lum, 5 * u) - lum, -1, 0)
    rgb = rgb + (occ * 0.3 * strength)[..., None]
    # gentle top-down key light
    H = rgb.shape[0]
    grad = np.linspace(0.04, -0.04, H, dtype=np.float32)[:, None, None]
    return rgb + grad * strength


def grade(rgb, sat=0.85, gamma=1.05, contrast=1.08):
    l = rgb.mean(-1, keepdims=True)
    rgb = l + (rgb - l) * sat
    rgb = (rgb - 0.5) * contrast + 0.5
    return np.clip(rgb, 0, 1) ** gamma


def ps1_output(rgb, res, colors, dither, out_size):
    H, W = rgb.shape[:2]
    rw = res if W >= H else round(res * W / H)
    rh = res if H >= W else round(res * H / W)
    small = np.clip(resize_rgb(rgb, rw, rh, Image.LANCZOS), 0, 1) * 255.0
    if dither:
        m = np.tile(PS1_DITHER, (rh // 4 + 1, rw // 4 + 1))[:rh, :rw]
        small = small + m[..., None]
    c15 = np.clip(small, 0, 255).astype(np.uint8) & 0xF8   # 5 bits per channel
    c15 = c15 | (c15 >> 5)                                  # expand back to 8-bit range
    img = Image.fromarray(c15, "RGB")
    if colors:
        img = img.quantize(colors=colors, method=Image.Quantize.MEDIANCUT,
                           dither=Image.Dither.NONE).convert("RGB")
    if out_size:
        img = img.resize(out_size, Image.NEAREST)
    return img


def process(path, args):
    src = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    H, W = src.shape[:2]
    k = detect_block(src) if args.block == 0 else args.block
    native = src.reshape(H // k, k, W // k, k, 3).mean(axis=(1, 3)) if k > 1 else src

    work = args.work or max(W, 256)
    wh = round(work * H / W)
    rgb = np.clip(resize_rgb(native / 255.0, work, wh, Image.BICUBIC), 0, 1)
    # keep a bit of the crisp art so faces stay readable
    crisp = resize_rgb(native / 255.0, work, wh, Image.NEAREST)
    rgb = rgb * 0.75 + crisp * 0.25

    seed = int(hashlib.md5(Path(path).name.encode()).hexdigest()[:8], 16) ^ args.seed
    rng = np.random.default_rng(seed)
    masks = material_masks(rgb, (args.skin_hue_min, args.skin_hue_max))
    rgb = add_detail(rgb, masks, rng, args.strength)
    rgb = bake_volume(rgb, args.strength, work / 256.0)
    rgb = grade(rgb, sat=args.saturation)

    out_size = None if args.keep_res else (W, H)
    img = ps1_output(rgb, args.res, args.colors, not args.no_dither, out_size)

    if args.debug_masks:
        m = np.stack([masks[0], masks[1], masks[2]], -1)
        Image.fromarray((m * 255).astype(np.uint8)).save(
            Path(args.output) / (Path(path).stem + "_masks.png"))
    return img, k


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input", help="image file or folder")
    p.add_argument("output", help="output folder")
    p.add_argument("--res", type=int, default=128, help="PS1 texture resolution (longest side), default 128")
    p.add_argument("--colors", type=int, default=256,
                   help="CLUT size: 256 (8-bit), 16 (4-bit) or 0 for 15-bit direct colour")
    p.add_argument("--strength", type=float, default=1.0, help="detail/shading amount, default 1.0")
    p.add_argument("--saturation", type=float, default=0.85)
    p.add_argument("--no-dither", action="store_true", help="disable PS1 ordered dithering")
    p.add_argument("--keep-res", action="store_true",
                   help="save at --res instead of scaling back to the input size")
    p.add_argument("--block", type=int, default=0, help="pixel-art block size (0 = auto detect)")
    p.add_argument("--work", type=int, default=0, help="internal working resolution (default max(input,256))")
    p.add_argument("--skin-hue-min", type=float, default=0.0)
    p.add_argument("--skin-hue-max", type=float, default=0.12)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--debug-masks", action="store_true", help="also write skin/hair/cloth masks (R/G/B)")
    args = p.parse_args()

    inp = Path(args.input)
    files = sorted(f for f in inp.rglob("*") if f.suffix.lower() in IMAGE_EXTS) if inp.is_dir() else [inp]
    if not files:
        sys.exit(f"no images found in {inp}")
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)

    for f in files:
        rel = f.relative_to(inp).with_suffix(".png") if inp.is_dir() else Path(f.stem + ".png")
        dst = out / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        img, k = process(f, args)
        img.save(dst)
        print(f"{f} -> {dst}  (block {k}px)")


if __name__ == "__main__":
    main()
