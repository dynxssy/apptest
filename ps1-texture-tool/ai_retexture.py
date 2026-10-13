#!/usr/bin/env python3
"""Batch AI re-texturing: pixel-art character textures -> photoreal textures
that keep the original UV layout, optionally finished with the PS1 look.

Uses Stable Diffusion 1.5 img2img + ControlNet "tile": the tile ControlNet
pins the result to the layout/colours of the source, while img2img invents
real detail (eyes, pores, stubble, hair strands, fabric).

Needs a GPU (NVIDIA ~6 GB+ VRAM, or Apple Silicon via MPS); first run
downloads ~4 GB of model weights from Hugging Face.

  pip install -r requirements-ai.txt
  python ai_retexture.py textures/ out/ --ps1
  python ai_retexture.py face.png out/ --prompt "old man, grey stubble" --strength 0.75

Per-file prompts: put a prompts.txt next to the inputs, one line per file:
  face_01.png: middle-aged man, grey hair, stubble beard, tanned skin
  jacket.png: worn black leather jacket, scuffed, stitched seams
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

from ps1ify import IMAGE_EXTS, detect_block, grade, ps1_output

BASE_PROMPT = ("photorealistic human texture map, UV unwrap, albedo, flat even studio lighting, "
               "raw photo scan, highly detailed skin pores, fine wrinkles, individual hair strands, "
               "realistic fabric weave, sharp focus, 8k")
NEGATIVE = ("pixel art, cartoon, illustration, painting, anime, 3d render, cgi, plastic skin, "
            "blurry, lowres, jpeg artifacts, harsh shadows, specular highlights, text, watermark, "
            "deformed, extra eyes, extra faces, duplicate face")


def prepare(path, size):
    """Recover the native pixel art and smooth-upscale it to `size` (long side)."""
    src = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    H, W = src.shape[:2]
    k = detect_block(src)
    if k > 1:
        src = src.reshape(H // k, k, W // k, k, 3).mean(axis=(1, 3))
    img = Image.fromarray(src.clip(0, 255).astype(np.uint8))
    w, h = (size, round(size * H / W)) if W >= H else (round(size * W / H), size)
    w, h = w // 8 * 8, h // 8 * 8                      # SD needs multiples of 8
    # bicubic + slight blur so the model doesn't reproduce the pixel grid
    img = img.resize((w, h), Image.BICUBIC).filter(ImageFilter.GaussianBlur(size / 512))
    return img, (W, H), k


def load_prompts(folder):
    f = folder / "prompts.txt"
    out = {}
    if f.exists():
        for line in f.read_text().splitlines():
            if ":" in line and not line.lstrip().startswith("#"):
                name, prompt = line.split(":", 1)
                out[name.strip()] = prompt.strip()
    return out


def load_pipeline(args):
    import torch
    from diffusers import (AutoencoderKL, ControlNetModel, DPMSolverMultistepScheduler,
                           StableDiffusionControlNetImg2ImgPipeline)

    if torch.cuda.is_available():
        device, dtype = "cuda", torch.float16
    elif torch.backends.mps.is_available():
        device, dtype = "mps", torch.float16
    else:
        print("warning: no GPU found, running on CPU (several minutes per image)", file=sys.stderr)
        device, dtype = "cpu", torch.float32

    controlnet = ControlNetModel.from_pretrained(args.controlnet, torch_dtype=dtype)
    vae = AutoencoderKL.from_pretrained(args.vae, torch_dtype=dtype)
    kw = dict(controlnet=controlnet, vae=vae, torch_dtype=dtype, safety_checker=None)
    if args.model.endswith((".safetensors", ".ckpt")):
        pipe = StableDiffusionControlNetImg2ImgPipeline.from_single_file(args.model, **kw)
    else:
        pipe = StableDiffusionControlNetImg2ImgPipeline.from_pretrained(args.model, **kw)
    pipe.scheduler = DPMSolverMultistepScheduler.from_config(
        pipe.scheduler.config, use_karras_sigmas=True)
    pipe = pipe.to(device)
    pipe.enable_attention_slicing()
    return pipe, device


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input", help="image file or folder")
    p.add_argument("output", help="output folder")
    p.add_argument("--prompt", default="", help="extra prompt for every image (e.g. 'old man, grey hair')")
    p.add_argument("--negative", default=NEGATIVE)
    p.add_argument("--strength", type=float, default=0.7,
                   help="how much the AI may change: 0.5 = close to source, 0.8 = much more invented")
    p.add_argument("--control", type=float, default=0.8,
                   help="ControlNet weight: higher keeps layout/colours closer to source")
    p.add_argument("--size", type=int, default=1024, help="generation resolution (long side)")
    p.add_argument("--steps", type=int, default=30)
    p.add_argument("--cfg", type=float, default=6.0)
    p.add_argument("--seed", type=int, default=1234)
    p.add_argument("--variants", type=int, default=1, help="images per input (different seeds)")
    p.add_argument("--model", default="SG161222/Realistic_Vision_V5.1_noVAE",
                   help="SD1.5 checkpoint: Hugging Face id or local .safetensors")
    p.add_argument("--controlnet", default="lllyasviel/control_v11f1e_sd15_tile")
    p.add_argument("--vae", default="stabilityai/sd-vae-ft-mse")
    p.add_argument("--ps1", action="store_true",
                   help="also write a PS1-finished copy (15-bit dither + CLUT) at the input size")
    p.add_argument("--ps1-res", type=int, default=256)
    p.add_argument("--ps1-colors", type=int, default=256)
    p.add_argument("--prep-only", action="store_true",
                   help="only write the upscaled init images (no AI), to check the prep step")
    args = p.parse_args()

    inp = Path(args.input)
    files = sorted(f for f in inp.rglob("*") if f.suffix.lower() in IMAGE_EXTS) if inp.is_dir() else [inp]
    if not files:
        sys.exit(f"no images found in {inp}")
    prompts = load_prompts(inp if inp.is_dir() else inp.parent)
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)

    pipe = device = None
    if not args.prep_only:
        import torch
        pipe, device = load_pipeline(args)

    for f in files:
        init, orig_size, k = prepare(f, args.size)
        stem = f.stem
        if args.prep_only:
            init.save(out / f"{stem}_init.png")
            print(f"{f} -> {stem}_init.png  (block {k}px, {init.size[0]}x{init.size[1]})")
            continue

        prompt = ", ".join(x for x in (prompts.get(f.name, ""), args.prompt, BASE_PROMPT) if x)
        for v in range(args.variants):
            gen = torch.Generator("cpu").manual_seed(args.seed + v)
            result = pipe(prompt=prompt, negative_prompt=args.negative,
                          image=init, control_image=init,
                          width=init.size[0], height=init.size[1],
                          strength=args.strength, num_inference_steps=args.steps,
                          guidance_scale=args.cfg, controlnet_conditioning_scale=args.control,
                          generator=gen).images[0]
            name = stem if args.variants == 1 else f"{stem}_v{v + 1}"
            result.save(out / f"{name}_real.png")
            msg = f"{f} -> {name}_real.png"
            if args.ps1:
                rgb = grade(np.asarray(result, np.float32) / 255.0, sat=0.85, gamma=1.0, contrast=1.0)
                ps1_output(rgb, args.ps1_res, args.ps1_colors, True, orig_size).save(out / f"{name}_ps1.png")
                msg += f", {name}_ps1.png"
            print(msg)


if __name__ == "__main__":
    main()
