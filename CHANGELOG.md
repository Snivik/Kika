# Changelog

Sloproom is in alpha. Every push to `main` that adds a new section here becomes a GitHub release:
CI builds the universal app and publishes the top section as its release notes (see README → Releases).
Fix releases bump the patch (0.1.0 → 0.1.1); significant new features bump the minor (→ 0.2.0).
Newest first; written for people, not commits.

## 0.1.1 — 2026-10-12

**Fixes**
- Opening an empty folder no longer crashes the app.
- After you drag photos onto a folder, the "Add" badge on the folder now goes away.
- The pointer no longer gets stuck as the zoom or hand cursor after you leave Develop.
- Crop shows clear pointers: a rotate arrow outside the crop rectangle (dragging there straightens the photo), resize
  arrows on the corners and edges, and a hand inside.

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
