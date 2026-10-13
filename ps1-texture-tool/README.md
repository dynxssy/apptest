# ps1ify — pixel-art → PS1-style human textures

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
