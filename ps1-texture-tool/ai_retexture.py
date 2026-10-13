#!/usr/bin/env python3
"""Batch AI re-texturing: pixel-art character textures -> photoreal textures
with the same UV layout, optionally finished with the PS1 look.

How it works (Stable Diffusion 1.5, runs on GPU or - slowly - CPU):
  1. Recover the native pixel art and find the face (the two eye pixels).
  2. Generate seamless photo swatches once per batch: hair, skin, cloth.
  3. Detail transfer: every region keeps the exact colour of the pixel art,
     and gets the real-photo detail of its material on top.
  4. Generate a frontal face photo, find its eyes (OpenCV) and warp it so
     its eyes land exactly on the pixel-art eyes; colour-match + blend it in.
  5. Optional --ps1: 15-bit dither + CLUT copy at the original size.

  pip install -r requirements-ai.txt
  python ai_retexture.py textures/ out/ --prompt "old man, grey hair, grey stubble beard" --ps1

Per-file prompts: prompts.txt next to the inputs, one line per file:
  face_01.png: young woman, long black hair, freckles
"""
import argparse
import hashlib
import sys
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image

from ps1ify import IMAGE_EXTS, blur, detect_block, grade, ps1_output

CACHE = Path.home() / ".cache" / "ps1ify"
NEGATIVE = ("drawing, painting, illustration, cartoon, anime, 3d render, cgi, plastic, blurry, "
            "lowres, jpeg artifacts, harsh shadows, text, watermark, frame, deformed")
FACE_PROMPT = ("raw photo, passport photo, frontal headshot of {p}, looking straight at the camera, "
               "neutral expression, symmetrical, even flat studio lighting, plain grey background, "
               "detailed skin pores, sharp focus, 8k")
SWATCH_PROMPTS = {
    "hair": "seamless texture, extreme close-up photo of {hair}, dense hair strands filling the "
            "whole frame, flat even lighting, no skin, sharp focus",
    "skin": "seamless texture, extreme close-up photo of human skin, {skin}, pores, fine "
            "wrinkles, flat even lighting, sharp focus",
    "cloth": "seamless texture, close-up photo of worn fabric, weave, creases, flat even "
             "lighting, sharp focus",
}
DETAIL_GAIN = {"hair": 1.6, "skin": 0.9, "cloth": 1.0}


# ----------------------------------------------------------------- analysis

def native_art(path):
    src = np.asarray(Image.open(path).convert("RGB")).astype(np.float32) / 255.0
    H, W = src.shape[:2]
    k = detect_block(src * 255)
    if k > 1:
        src = src.reshape(H // k, k, W // k, k, 3).mean(axis=(1, 3))
    return src, (W, H), k


def classify(n):
    """Per native pixel: 0 = skin, 1 = hair/other, 2 = small dark feature."""
    r, g, b = n[..., 0], n[..., 1], n[..., 2]
    lum = n.mean(-1)
    skin = (r - b > 0.06) & (r > g) & (lum > 0.25)
    cls = np.where(skin, 0, 1)
    return cls, lum


def find_eyes(n, cls, lum):
    """Two small dark pixels side by side inside skin -> eye centres (native px)."""
    skin_lum = np.median(lum[cls == 0]) if (cls == 0).any() else 0.5
    dark = lum < skin_lum * 0.55
    H, W = lum.shape
    cand = []
    for y in range(1, H - 1):
        for x in range(1, W - 1):
            if dark[y, x] and (cls[y - 1:y + 2, x - 1:x + 2] == 0).sum() >= 4 \
                    and dark[y - 1:y + 2, x - 1:x + 2].sum() <= 3:
                cand.append((y, x))
    best = None
    for i, (y1, x1) in enumerate(cand):
        for y2, x2 in cand[i + 1:]:
            dx = abs(x2 - x1)
            if abs(y2 - y1) <= 1 and 3 <= dx <= W // 3:
                pair = ((x1 + 0.5, y1 + 0.5), (x2 + 0.5, y2 + 0.5))
                pair = tuple(sorted(pair))
                if best is None or y1 < best[0][1]:   # topmost pair
                    best = pair
    return best


# ----------------------------------------------------------------- generation

class Generator:
    def __init__(self, args):
        import torch
        from diffusers import AutoencoderKL, DPMSolverMultistepScheduler, StableDiffusionPipeline

        self.torch = torch
        if torch.cuda.is_available():
            self.device, dtype = "cuda", torch.float16
        elif torch.backends.mps.is_available():
            self.device, dtype = "mps", torch.float16
        else:
            print("note: no GPU found, running on CPU (a few minutes per image)", file=sys.stderr)
            self.device, dtype = "cpu", torch.float32
        vae = AutoencoderKL.from_pretrained(args.vae, torch_dtype=dtype)
        kw = dict(vae=vae, torch_dtype=dtype, safety_checker=None, requires_safety_checker=False)
        if args.model.endswith((".safetensors", ".ckpt")):
            pipe = StableDiffusionPipeline.from_single_file(args.model, **kw)
        else:
            pipe = StableDiffusionPipeline.from_pretrained(args.model, **kw)
        pipe.scheduler = DPMSolverMultistepScheduler.from_config(
            pipe.scheduler.config, algorithm_type="dpmsolver++", use_karras_sigmas=True)
        self.pipe = pipe.to(self.device)
        self.pipe.set_progress_bar_config(disable=True)
        self.convs = [m for m in list(pipe.unet.modules()) + list(pipe.vae.modules())
                      if isinstance(m, torch.nn.Conv2d)]
        self.args = args

    def __call__(self, prompt, w, h, seed, tileable=False):
        for m in self.convs:   # circular padding => seamless tiling texture
            m.padding_mode = "circular" if tileable else "zeros"
        g = self.torch.Generator("cpu").manual_seed(seed)
        return self.pipe(prompt=prompt, negative_prompt=self.args.negative, width=w, height=h,
                         num_inference_steps=self.args.steps, guidance_scale=self.args.cfg,
                         generator=g).images[0]


def swatch(gen, kind, args):
    prompt = SWATCH_PROMPTS[kind].format(hair=args.hair, skin=args.skin)
    key = hashlib.md5(f"{prompt}|{args.model}|{args.steps}|{args.seed}".encode()).hexdigest()[:12]
    f = CACHE / f"swatch_{kind}_{key}.png"
    if not f.exists():
        print(f"  generating {kind} swatch...")
        CACHE.mkdir(parents=True, exist_ok=True)
        gen(prompt, 512, 512, args.seed, tileable=True).save(f)
    return np.asarray(Image.open(f).convert("RGB"), np.float32) / 255.0


def cascades():
    import cv2
    out = []
    for name in ("haarcascade_frontalface_default.xml", "haarcascade_eye.xml"):
        f = CACHE / name
        if not f.exists():
            CACHE.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(
                f"https://raw.githubusercontent.com/opencv/opencv/4.x/data/haarcascades/{name}", f)
        out.append(cv2.CascadeClassifier(str(f)))
    return out


def detect_photo_eyes(img):
    """Eye centres (left, right) in a generated portrait, or None."""
    import cv2
    face_c, eye_c = cascades()
    gray = cv2.equalizeHist(cv2.cvtColor(np.asarray(img), cv2.COLOR_RGB2GRAY))
    faces = face_c.detectMultiScale(gray, 1.1, 5, minSize=(120, 120))
    if len(faces) == 0:
        return None
    fx, fy, fw, fh = max(faces, key=lambda r: r[2] * r[3])
    roi = gray[fy:fy + fh // 2 + fh // 8, fx:fx + fw]
    eyes = eye_c.detectMultiScale(roi, 1.05, 6, minSize=(fw // 10, fw // 10))
    eyes = sorted(eyes, key=lambda e: -e[2])[:4]
    best = None
    for i in range(len(eyes)):
        for j in range(i + 1, len(eyes)):
            a, b = eyes[i], eyes[j]
            ca = (fx + a[0] + a[2] / 2, fy + a[1] + a[3] / 2)
            cb = (fx + b[0] + b[2] / 2, fy + b[1] + b[3] / 2)
            if abs(ca[1] - cb[1]) < fh * 0.08 and abs(ca[0] - cb[0]) > fw * 0.25:
                best = tuple(sorted((ca, cb)))
                break
        if best:
            break
    if best is None:   # fall back to typical eye placement inside the face box
        best = ((fx + fw * 0.31, fy + fh * 0.40), (fx + fw * 0.69, fy + fh * 0.40))
    return best


def make_face(gen, prompt, seed, tries):
    for t in range(tries):
        img = gen(FACE_PROMPT.format(p=prompt), 512, 640, seed + 101 * t)
        eyes = detect_photo_eyes(img)
        if eyes:
            return img, eyes
        print("  no face found in generated portrait, retrying...")
    return None, None


# ----------------------------------------------------------------- compositing

def tiled(sw, h, w, scale):
    if scale != 1:
        s = max(16, int(sw.shape[0] * scale))
        sw = np.asarray(Image.fromarray((sw * 255).astype(np.uint8)).resize((s, s), Image.LANCZOS),
                        np.float32) / 255.0
    reps = (h // sw.shape[0] + 1, w // sw.shape[1] + 1, 1)
    return np.tile(sw, reps)[:h, :w]


def detail_ratio(sw, sigma):
    l = sw.mean(-1) + 0.02
    return l / (blur(l, sigma) + 1e-4)


def warp_face(face, src_eyes, dst_eyes, size):
    """Similarity transform taking src eye pair onto dst eye pair."""
    import cv2
    (sx1, sy1), (sx2, sy2) = src_eyes
    (dx1, dy1), (dx2, dy2) = dst_eyes
    vs, vd = complex(sx2 - sx1, sy2 - sy1), complex(dx2 - dx1, dy2 - dy1)
    m = vd / vs
    a, b = m.real, m.imag
    tx = dx1 - (a * sx1 - b * sy1)
    ty = dy1 - (b * sx1 + a * sy1)
    M = np.array([[a, -b, tx], [b, a, ty]], np.float32)
    W, H = size
    f = cv2.warpAffine(np.asarray(face, np.float32) / 255.0, M, (W, H),
                       flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REFLECT)
    return f


def compose(n, cls, eyes, swatches, face, face_eyes, out_px, args):
    h, w = n.shape[:2]
    s = out_px // w                      # canvas pixels per native pixel
    H, W = h * s, w * s
    base = np.asarray(Image.fromarray((n * 255).astype(np.uint8)).resize((W, H), Image.NEAREST),
                      np.float32) / 255.0
    base = np.stack([blur(base[..., c], s * 0.35) for c in range(3)], -1)
    m_skin = np.asarray(Image.fromarray((cls == 0).astype(np.uint8) * 255).resize((W, H), Image.NEAREST),
                        np.float32) / 255.0
    m_skin = blur(m_skin, s * 0.3)
    other = "hair" if eyes else "cloth"
    tex = s / 16.0                       # swatch scale relative to a 1024 canvas
    r_skin = detail_ratio(tiled(swatches["skin"], H, W, tex), 24 * tex)
    r_other = detail_ratio(tiled(swatches[other], H, W, tex), 24 * tex)
    ratio = m_skin * r_skin ** DETAIL_GAIN["skin"] + (1 - m_skin) * r_other ** DETAIL_GAIN[other]
    out = np.clip(base * ratio[..., None] ** args.detail, 0, 1)

    if face is not None:
        (ex1, ey1), (ex2, ey2) = eyes
        dst = ((ex1 * s, ey1 * s), (ex2 * s, ey2 * s))
        f = warp_face(face, face_eyes, dst, (W, H))
        d = (ex2 - ex1) * s
        cx, cy = (ex1 + ex2) / 2 * s, (ey1 + ey2) / 2 * s
        yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
        # ellipse from forehead/hairline down past the chin
        cy0 = cy + d * 0.45
        rx, ry = d * 1.35, d * 2.05
        e = ((xx - cx) / rx) ** 2 + ((yy - cy0) / ry) ** 2
        mask = np.clip((1.0 - e) / 0.25, 0, 1)
        mask = blur(mask, d * 0.08)
        # match the face's skin tone to the texture's skin colour
        cheek = (np.abs(xx - cx) < d * 0.6) & (yy > cy + d * 0.25) & (yy < cy + d * 0.7)
        sk = base[(m_skin > 0.9)]
        target = sk.mean(0) if len(sk) else base[cheek].mean(0)
        f = f * (target / (f[cheek].mean(0) + 1e-4)) ** args.face_match
        out = out * (1 - mask[..., None]) + np.clip(f, 0, 1) * mask[..., None]
    return out


# ----------------------------------------------------------------- main

def load_prompts(folder):
    f = folder / "prompts.txt"
    out = {}
    if f.exists():
        for line in f.read_text().splitlines():
            if ":" in line and not line.lstrip().startswith("#"):
                name, prompt = line.split(":", 1)
                out[name.strip()] = prompt.strip()
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input", help="image file or folder")
    p.add_argument("output", help="output folder")
    p.add_argument("--prompt", default="middle-aged man",
                   help="who the face is, e.g. 'old man, grey hair, grey stubble beard'")
    p.add_argument("--hair", default="grey human hair", help="hair swatch description")
    p.add_argument("--skin", default="light skin", help="skin swatch description")
    p.add_argument("--negative", default=NEGATIVE)
    p.add_argument("--size", type=int, default=1024, help="output canvas size before PS1 step")
    p.add_argument("--detail", type=float, default=1.0, help="strength of transferred photo detail")
    p.add_argument("--face-match", type=float, default=0.8,
                   help="0..1 how strongly the face is tinted to the texture's skin colour")
    p.add_argument("--steps", type=int, default=25)
    p.add_argument("--cfg", type=float, default=6.5)
    p.add_argument("--seed", type=int, default=1234)
    p.add_argument("--variants", type=int, default=1, help="different faces per input")
    p.add_argument("--model", default="SG161222/Realistic_Vision_V5.1_noVAE",
                   help="SD1.5 checkpoint: Hugging Face id or local .safetensors")
    p.add_argument("--vae", default="stabilityai/sd-vae-ft-mse")
    p.add_argument("--ps1", action="store_true",
                   help="also write a PS1-finished copy (15-bit dither + CLUT) at the input size")
    p.add_argument("--ps1-res", type=int, default=256)
    p.add_argument("--ps1-colors", type=int, default=256)
    args = p.parse_args()

    inp = Path(args.input)
    files = sorted(f for f in inp.rglob("*") if f.suffix.lower() in IMAGE_EXTS) if inp.is_dir() else [inp]
    if not files:
        sys.exit(f"no images found in {inp}")
    prompts = load_prompts(inp if inp.is_dir() else inp.parent)
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)

    gen = Generator(args)
    swatches = {}
    for f in files:
        n, orig_size, k = native_art(f)
        cls, lum = classify(n)
        eyes = find_eyes(n, cls, lum)
        print(f"{f}: block {k}px, " + (f"eyes at {eyes}" if eyes else "no face (cloth mode)"))
        for kind in ("skin", "hair" if eyes else "cloth"):
            if kind not in swatches:
                swatches[kind] = swatch(gen, kind, args)
        who = prompts.get(f.name, args.prompt)
        for v in range(args.variants):
            face = face_eyes = None
            if eyes:
                print("  generating face...")
                face, face_eyes = make_face(gen, who, args.seed + 1000 * v, tries=3)
            img = compose(n, cls, eyes, swatches, face, face_eyes, args.size, args)
            name = f.stem if args.variants == 1 else f"{f.stem}_v{v + 1}"
            Image.fromarray((img * 255).astype(np.uint8)).save(out / f"{name}_real.png")
            if face is not None:
                face.save(out / f"{name}_face.png")
            msg = f"  -> {name}_real.png"
            if args.ps1:
                rgb = grade(img, sat=0.9, gamma=1.0, contrast=1.0)
                ps1_output(rgb, args.ps1_res, args.ps1_colors, True, orig_size).save(out / f"{name}_ps1.png")
                msg += f", {name}_ps1.png"
            print(msg)


if __name__ == "__main__":
    main()
