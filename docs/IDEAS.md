# Project ideas

Possible future projects. Not commitments, and not documentation of the current code (that is
`ARCHITECTURE.md`). Each entry says what it is, why it might be worth doing, and what we know so far.

## Match camera JPEG (decode profile fitting)

**Idea.** Fit a camera's decode profile (boost, boost shadow, shadow bias, baseline offset, shoulder) so the
pipeline matches the camera's own JPEGs (paired `.JPG` or embedded preview) over 20–50 photos.
Noise reduction and sharpening stay Auto (a downsized preview can't measure them). It also fixes
brightness matching for profiles with a different base curve (`BaselineExposure` is measured at boost 1).

*Done (2026-10-12): per-edit decoder pinning and the calibration UI are now Decode profiles; see
ARCHITECTURE.md › Decode profiles.*

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
a high-ISO file in Sloproom (Apple), LightCraft and Lightroom. Reference portrait:
`/Volumes/T9/Lightroom/2026/2026-10-11/P1033881.RW2`.
