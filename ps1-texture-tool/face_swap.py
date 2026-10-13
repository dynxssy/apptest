#!/usr/bin/env python3
"""Fast "uncanny" PS1 face swap: paste a real photo face onto pixel-art head
textures, lined up with the pixel-art eyes (and mouth), then give the result
the PS1 finish.  No GPU or AI model needed: about a second per texture.

Faces come from thispersondoesnotexist.com (StyleGAN, a new random person on
every request), or from your own folder of FFHQ-aligned 1024x1024 faces
(--faces).  StyleGAN faces are always aligned the same way: eyes at
~(373,480) and (633,480), mouth at y~750, which is what makes this work.

The rest of the texture (hair, neck, body) gets ps1ify's procedural detail.

  python face_swap.py textures/ out/
  python face_swap.py face.png out/ --faces my_faces/ --res 128 --colors 16
"""
import argparse
import hashlib
import sys
import time
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image

from ai_retexture import classify, find_eyes
from ps1ify import IMAGE_EXTS, blur, build_parser, detect_block, enhance, grade, ps1_output

URL = "https://thispersondoesnotexist.com/random-person.jpeg"
# landmark positions in a 1024x1024 StyleGAN/FFHQ-aligned face
SRC_EYES = ((373.0, 480.0), (633.0, 480.0))
SRC_MOUTH_Y = 750.0
SRC_MASK = (506.0, 610.0, 290.0, 360.0)        # face ellipse: cx, cy, rx, ry
SRC_CHEEKS = [(300, 560, 420, 680), (600, 560, 720, 680)]


def fetch_face(dst):
    req = urllib.request.Request(f"{URL}?t={time.time_ns()}",
                                 headers={"User-Agent": "Mozilla/5.0", "Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read()
    if not data.startswith(b"\xff\xd8"):
        raise RuntimeError("thispersondoesnotexist.com did not return a JPEG")
    dst.write_bytes(data)
    return Image.open(dst).convert("RGB")


def find_mouth(n, cls, lum, eyes):
    """Lowest horizontal dark run between/below the eyes -> mouth centre y (native px)."""
    (x1, ey), (x2, _) = eyes
    d = x2 - x1
    skin_lum = np.median(lum[cls == 0])
    dark = lum < skin_lum * 0.88
    xa, xb = int(x1 - 1), int(x2 + 1)
    rows = []
    for y in range(int(ey) + 2, min(lum.shape[0], int(ey + 3 * d))):
        run = best = 0
        for x in range(max(0, xa), min(lum.shape[1], xb + 1)):
            run = run + 1 if dark[y, x] else 0
            best = max(best, run)
        if best >= 3:
            rows.append(y)
    if not rows:
        return None
    group = [rows[-1]]                            # lowest group of consecutive rows
    for y in reversed(rows[:-1]):
        if y == group[-1] - 1:
            group.append(y)
        else:
            break
    return (min(group) + max(group)) / 2 + 0.5


def fill_holes(skin):
    """Fill non-skin areas fully enclosed by skin (eyes, nose, mouth)."""
    other = ~skin
    reach = np.zeros_like(other)
    reach[0, :], reach[-1, :], reach[:, 0], reach[:, -1] = other[0, :], other[-1, :], other[:, 0], other[:, -1]
    while True:   # flood fill from the image border through non-skin pixels
        grown = reach.copy()
        grown[1:] |= reach[:-1]
        grown[:-1] |= reach[1:]
        grown[:, 1:] |= reach[:, :-1]
        grown[:, :-1] |= reach[:, 1:]
        grown &= other
        if (grown == reach).all():
            return ~reach
        reach = grown


def paste_face(canvas, base_skin, skin_mask, face, eyes, mouth_y, s, args):
    """Warp `face` so its eyes/mouth land on the texture's, colour-match, blend."""
    H, W = canvas.shape[:2]
    (sx1, sy), (sx2, _) = SRC_EYES
    (dx1, dy), (dx2, _) = ((e[0] * s, e[1] * s) for e in eyes)
    scale_x = (dx2 - dx1) / (sx2 - sx1) * args.face_scale
    scale_y = scale_x
    if mouth_y is not None and not args.no_mouth:
        scale_y = (mouth_y * s - dy) / (SRC_MOUTH_Y - sy) * args.face_scale
        scale_y = float(np.clip(scale_y, scale_x * 0.8, scale_x * args.max_stretch))
    scx, scy = (sx1 + sx2) / 2, sy
    dcx = (dx1 + dx2) / 2

    f = np.asarray(face, np.float32) / 255.0
    # match the photo's skin tone to the texture's skin colour
    cheek = np.concatenate([f[y0:y1, x0:x1].reshape(-1, 3) for x0, y0, x1, y1 in SRC_CHEEKS])
    f = np.clip(f * (base_skin / (cheek.mean(0) + 1e-4)) ** args.face_match, 0, 1)

    cx, cy, rx, ry = SRC_MASK
    yy, xx = np.mgrid[0:1024, 0:1024].astype(np.float32)
    e = ((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2
    mask = blur(np.clip((1 - e) / 0.15, 0, 1), 18)

    rgba = np.concatenate([f, mask[..., None]], -1)
    # output (x, y) -> source pixel: inverse of the eye/mouth alignment
    inv = (1 / scale_x, 0, scx - dcx / scale_x, 0, 1 / scale_y, scy - dy / scale_y)
    warped = []
    for c in range(4):
        ch = Image.fromarray(rgba[..., c], "F").transform((W, H), Image.AFFINE, inv, Image.BICUBIC)
        warped.append(np.asarray(ch))
    warped = np.stack(warped, -1)
    a = np.clip(warped[..., 3:], 0, 1) * args.opacity
    if not args.over_hair:   # keep the photo inside the texture's skin area
        a = a * skin_mask[..., None]
    return canvas * (1 - a) + np.clip(warped[..., :3], 0, 1) * a


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input", help="image file or folder")
    p.add_argument("output", help="output folder")
    p.add_argument("--faces", help="folder of FFHQ-aligned 1024px faces to use instead of downloading")
    p.add_argument("--size", type=int, default=1024, help="working canvas size")
    p.add_argument("--res", type=int, default=256, help="PS1 texture resolution (longest side)")
    p.add_argument("--colors", type=int, default=256, help="CLUT size 256/16, 0 = 15-bit")
    p.add_argument("--face-match", type=float, default=0.85,
                   help="0..1 how strongly the photo is tinted to the texture's skin colour")
    p.add_argument("--opacity", type=float, default=1.0)
    p.add_argument("--face-scale", type=float, default=1.15,
                   help="face size relative to the pixel-art eye spacing")
    p.add_argument("--over-hair", action="store_true",
                   help="let the photo (forehead/hairline) spill over hair areas")
    p.add_argument("--max-stretch", type=float, default=1.8,
                   help="max vertical stretch to reach the pixel-art mouth (uncanny factor)")
    p.add_argument("--no-mouth", action="store_true", help="only align eyes, keep photo proportions")
    p.add_argument("--strength", type=float, default=0.8, help="procedural detail on the rest")
    p.add_argument("--seed", type=int, default=0)
    args = p.parse_args()

    inp = Path(args.input)
    files = sorted(f for f in inp.rglob("*") if f.suffix.lower() in IMAGE_EXTS) if inp.is_dir() else [inp]
    if not files:
        sys.exit(f"no images found in {inp}")
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    local = sorted(f for f in Path(args.faces).iterdir() if f.suffix.lower() in IMAGE_EXTS) \
        if args.faces else []

    for i, f in enumerate(files):
        src = np.asarray(Image.open(f).convert("RGB")).astype(np.float32)
        H, W = src.shape[:2]
        k = detect_block(src)
        n = src.reshape(H // k, k, W // k, k, 3).mean(axis=(1, 3)) / 255.0 if k > 1 else src / 255.0
        cls, lum = classify(n)
        eyes = find_eyes(n, cls, lum)
        if eyes is None:
            # non-human skin tones (blue, grey, ...): treat every light pixel as skin
            cls = np.where(lum > max(0.3, np.percentile(lum, 30)), 0, 1)
            eyes = find_eyes(n, cls, lum)

        # procedural ps1ify detail for everything that isn't the face
        pargs = build_parser().parse_args(["in", "out", "--work", str(args.size),
                                           "--strength", str(args.strength), "--seed", str(args.seed)])
        canvas, _, _ = enhance(src, f.name, pargs)

        if eyes is None:
            print(f"{f}: no eyes found, only procedural detail")
        else:
            mouth = find_mouth(n, cls, lum, eyes)
            if local:
                h = int(hashlib.md5(f.name.encode()).hexdigest()[:8], 16) + args.seed
                face_path = local[h % len(local)]
                face = Image.open(face_path).convert("RGB").resize((1024, 1024), Image.LANCZOS)
            else:
                face_path = out / f"{f.stem}_face.jpg"
                face = fetch_face(face_path)
                if i + 1 < len(files):
                    time.sleep(1.0)               # be polite to the site
            s = canvas.shape[1] / n.shape[1]      # canvas px per native px
            skin = n[cls == 0].mean(0)
            Hc, Wc = canvas.shape[:2]
            m = fill_holes(cls == 0).astype(np.uint8)
            m = Image.fromarray(m * 255).resize((Wc, Hc), Image.NEAREST)
            m = blur(np.asarray(m, np.float32) / 255.0, s * 0.4)
            canvas = paste_face(canvas, skin, m, face, eyes, mouth, s, args)
            print(f"{f}: eyes {eyes}, mouth y {mouth}, face {face_path.name}")

        Image.fromarray((np.clip(canvas, 0, 1) * 255).astype(np.uint8)).save(out / f"{f.stem}_real.png")
        rgb = grade(np.clip(canvas, 0, 1), sat=0.9, gamma=1.0, contrast=1.0)
        ps1_output(rgb, args.res, args.colors, True, (W, H)).save(out / f"{f.stem}_ps1.png")


if __name__ == "__main__":
    main()
