# ps1ify — pixel-art → PS1-style human textures

Two tools:

* **`ai_retexture.py`**: photoreal results (real eyes, pores, stubble, hair strands)
  that keep your UV layout. It uses Stable Diffusion img2img + ControlNet tile and needs a GPU.
* **`ps1ify.py`**: procedural detail plus the PS1 finish. CPU only, instant.
  `--finish-only` applies just the PS1 look (downsample, 15-bit dither, CLUT) to photoreal textures.

## AI re-texturing (photoreal)

```sh
pip install -r requirements-ai.txt          # install torch with CUDA first if on NVIDIA
python ai_retexture.py textures/ out/ --ps1 # writes *_real.png and *_ps1.png
```

* `--strength` (0.7): how much the AI may invent. Use 0.55 to stay close to the source and 0.8 for more realism.
* `--control` (0.8): how strictly it keeps the layout and colours of the source.
* `--prompt "old man, grey hair, stubble"` applies to every image, or use a `prompts.txt` next to
  the inputs with lines like `face_01.png: old man, grey hair, stubble`.
* `--variants 4` makes 4 seeds per texture so you can pick the best.
* `--model` takes any SD1.5 checkpoint (HF id or local `.safetensors`). The default is Realistic Vision 5.1.
* `--prep-only` skips the AI and only writes the cleaned, upscaled input it would feed the model.

Tip: put face textures and clothing atlases in separate folders and give each its own prompt.

## Procedural / PS1 finish

Batch-converts flat pixel-art character textures (faces, skin, clothing atlases)
into grittier, more "realistic" PlayStation 1–era textures. Pure numpy + Pillow,
deterministic, no GPU or AI model needed.

```sh
pip install numpy pillow
python ps1ify.py my_textures/ out/                    # whole folder (recursive)
python ps1ify.py face.png out/ --res 64 --colors 16   # crunchy 4-bit CLUT look
```

What it does per image:

1. Auto-detects the pixel-art block size (e.g. 4px) and recovers the native art.
2. Smooth-upscales it, keeping some of the crisp pixels so faces stay readable.
3. Soft-classifies pixels as **skin** (orange hues), **hair** (very dark) or **cloth** (everything else).
4. Adds tileable procedural detail: skin blotches/redness/pores, hair strands and clumps,
   cloth weave/fibres/folds/wear.
5. Bakes fake lighting: local contrast, soft occlusion under hair and around features, top-down key light.
6. PS1 output: downsample to texture res, 15-bit colour with the real PS1 4×4 dither
   matrix, optional 256/16-colour CLUT, nearest-neighbour back to input size.

| option | default | meaning |
|---|---|---|
| `--res` | 128 | PS1 texture resolution (longest side). 64 = very low-fi |
| `--colors` | 256 | CLUT size: 256, 16, or 0 for 15-bit direct colour |
| `--strength` | 1.0 | amount of detail + shading |
| `--saturation` | 0.85 | colour grading |
| `--no-dither` | off | disable PS1 ordered dithering |
| `--keep-res` | off | save at `--res` instead of the input size |
| `--block` | 0 (auto) | force the pixel-art block size |
| `--skin-hue-min/max` | 0.0 / 0.12 | hue range counted as skin (0–1) |
| `--seed` | 0 | change the noise (per-file seed is derived from the filename) |
| `--debug-masks` | off | also write `*_masks.png` (R=skin, G=hair, B=cloth) |

Non-orange skin (e.g. blue/grey "wet" faces) is treated as cloth unless you widen the
skin hue range, e.g. `--skin-hue-min 0.5 --skin-hue-max 0.6` for blue-grey.
