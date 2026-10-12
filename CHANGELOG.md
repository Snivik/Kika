# Changelog

Sloproom is in alpha. Every push to `main` that adds a new section here becomes a GitHub release:
CI builds the universal app and publishes the top section as its release notes (see README → Releases).
Versions go up one minor per release (0.1.0, 0.2.0, …). Newest first; written for people, not commits.

## 0.2.0 — 2026-10-12

**Fixes**
- Opening an empty folder no longer crashes the app.
- After you drag photos onto a folder, the "Add" badge on the folder now goes away.
- After you leave Develop while zoomed in, the Library goes back to the normal pointer instead of the zoom or hand cursor.
- In Crop, the pointer outside the crop rectangle now shows a rotate arrow, since dragging there straightens the photo.

## 0.1.0 — 2026-10-12

First release.

**Library**
- Import from external drives and organise your catalog.
- Duplicate detection on import, and moves between folders happen in place.
- Import an existing Lightroom catalog to get going.

**Develop**
- Basic exposure, tone and crop.
- Copy and paste settings between photos.

**RAW**
- RAW files are decoded with Apple's RAW decoder. It's a rich, well-maintained camera database that
  every Mac already has, and its defaults are good. I'm not currently planning an open-source, bare-metal
  alternative.
- Extended decode settings for RAW files, including an algorithm that matches a camera's settings to
  the JPEGs embedded in its RAW files. This gives you good-enough per-camera defaults to get going with
  pretty much any camera.
