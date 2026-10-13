# Project ideas

Possible future projects. Not commitments, and not documentation of the current code (that is
`ARCHITECTURE.md`). Each entry says what it is, why it might be worth doing, and what we know so far.

*Done (2026-10-12): per-edit decoder pinning, the calibration UI and Match Camera JPEG are now Decode
profiles; see ARCHITECTURE.md › Decode profiles.*

## Workflows that tag photos

**Idea.** Run a job over a set of photos (e.g. "is it blurry?", "eyes closed?", "duplicate burst") that writes
tag values as its own author (`workflow:<name>`), so the owner reviews a small "To Review" set instead of everything.

**What we have (2026-10-12).** Tags with per-author values, effective value, To Review rows and Confirm
(ARCHITECTURE.md › Tags). Missing: a way to run a workflow (in-app job vs external tool writing the catalog;
an external writer needs the app to notice changes, e.g. a file presenter or a "Reload" command), and the
detectors themselves (sharpness from a Laplacian-variance on the preview is a cheap first blur check).

## Pluggable RAW front end: Apple native or our own decoder and demosaic

**Idea.** Let the user choose, per photo or globally, between Apple's RAW decoding (`CIRAWFilter`, today's
only path) and our own: file decoding, black level, white balance, demosaic, camera colour, in Swift and Metal.
Later, add a machine-learned demosaic as a further option.

**Why.** Demosaicing is where most of the fine-detail differences between raw developers come from
(false colour and moiré on fabric, zipper edges, high-ISO noise). Owning it would also give us the raw
mosaic for things `CIRAWFilter` can't do, e.g. pixel-shift merging or joint demosaic and denoise.

**What we know (2026-10-12).**

- `CIRAWFilter` is a black box from file to RGB. It has no API to receive the raw mosaic or plug in a
  demosaic. `linearSpaceFilter` runs after demosaicing. Swapping the demosaic therefore means replacing
  the whole front end:
  1. file unpacking,
  2. black level and linearisation,
  3. white balance,
  4. demosaic,
  5. camera colour,
  6. lens corrections.
- **File decoding:**
  - LibRaw (LGPL, C++, every camera).
  - LightCraft's pure-Rust decoders (Apache-2.0, portable with attribution).
  - Adobe DNG SDK (permissive, DNG only).
  - Avoid GPL code (RawTherapee, darktable).
- **Demosaic:** classic algorithms are published papers (AHD, VNG, RCD, AMaZE, Menon) and can be
  implemented clean-room as Metal kernels.
- **Machine-learned demosaic:**
  - Adobe ("Enhance Details", AI Denoise) and DxO (DeepPRIME) are proprietary.
  - Open research exists, e.g. Gharbi et al., "Deep Joint Demosaicking and Denoising" (SIGGRAPH Asia 2016,
    `demosaicnet`), which could be converted to Core ML.
  - The gain is mostly at high ISO.
- **Camera colour is the hard part:**
  - DNGs carry their own colour matrices.
  - Proprietary formats (Panasonic RW2, etc.) need a per-camera table.
  - Apple's per-camera profiles are a big reason to keep the native path as the default.
- **Cheaper first step (planned separately):** keep `CIRAWFilter` but set `boostAmount = 0` (scene-linear
  output) and own the tone curve. This also gives a calibration / developer mode with live knobs for the
  decode and tone steps.

**How to evaluate before starting.** Compare 100% crops of fine textures (knitwear, foliage, fences) and
a high-ISO file in Кика (Apple), LightCraft and Lightroom. Reference portrait:
`/Volumes/T9/Lightroom/2026/2026-10-11/P1033881.RW2`.
