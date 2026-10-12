# Changelog

Sloproom is in alpha. Every push to `main` that adds a new section here becomes a GitHub release:
CI builds the universal app and publishes the top section as its release notes (see README → Releases).
Versions go up one minor per release (0.1.0, 0.2.0, …). Newest first; written for people, not commits.

## 0.1.0 — 2026-10-12

The first alpha: a native Mac photo library and RAW editor in the spirit of Lightroom Classic.

**Library**
- Catalog of your photos with folders, picks / rejects, filmstrip with multi-select and drag & drop,
  and a grid grouped by date.
- Import from SD cards and folders with a review page: destination folder tree, duplicate detection,
  a prompt when files already exist, and a recap at the end. Copying to exFAT drives works.
- Import a Lightroom Classic catalog: photos, collections as folders, flags and ratings (not edits).
- Virtual copies, Copy to Folder, and Finder-style drop modifiers.
- Export and import the whole catalog with automatic backups, and relink photos when a drive is renamed.

**Develop**
- Exposure, tone, presence and colour sliders tuned to feel like Lightroom's on the same files.
- Crop, straighten and Bulk Crop; linear, radial and brush masks.
- Zoom and pan with pinch, smart magnify and keyboard, full-screen preview, Tab to hide panels.
- Copy / paste / sync settings across many photos, undone in one step.
- Recently rendered photos open instantly, and the next photos are prepared ahead of time.

**RAW decoding**
- Bright skin in sunsets and other warm highlights no longer bleaches out.
- Raw Decode panel and Settings tab: Apple's RAW decoder settings (noise reduction, sharpening, boost,
  lens correction, …) as profiles you can set per photo, per camera, or for everything, then copy,
  export and import. Every setting explains itself on hover.
- Match Camera JPEG: builds a camera profile that looks like your camera's own JPEGs, from 16, 32 or 64
  of your photos. Each run makes a new profile, so you can compare them.
- Fill In Camera Makes: merges cameras that Lightroom imports listed twice (once without the make).

**Everywhere**
- Every keyboard shortcut can be changed in Settings, and controls have tooltips.
