# Sloproom

A native Mac photo library and RAW editor in the spirit of Lightroom Classic. It's built with SwiftUI and
Apple's RAW engine and has no third-party dependencies.

> **Alpha.** Sloproom is a personal project under active development. Back up your catalog
> (File → Export Catalog) before updating.

<!-- Screenshots: put PNGs in docs/screenshots/ and reference them here, e.g.
![Library](docs/screenshots/library.png)
![Develop](docs/screenshots/develop.png)
-->

## Install

1. Download the latest `Sloproom-<version>-alpha-universal.zip` from
   [Releases](https://github.com/Snivik/Sloproom/releases). It runs on Apple Silicon and Intel with macOS 15 or later.
2. Unzip it and move `Sloproom.app` to Applications.
3. The app isn't notarized, so macOS blocks the first launch. Open it once, then choose
   System Settings → Privacy & Security → **Open Anyway**. You can also run this instead:

```bash
xattr -dr com.apple.quarantine /Applications/Sloproom.app
```

## What it does

See [CHANGELOG.md](CHANGELOG.md) for what's in each release. In short:

- **Library:** a catalog with folders, picks and rejects, and a filmstrip.
- **Tags:** on photos and folders, set by you or suggested by a workflow, with a To Review set and one filter for flags, ratings and tags.
- **Import:** from cards or folders with a review step, or from a Lightroom Classic catalog.
- **Develop:** Lightroom-calibrated sliders, crop, masks, zoom, and copy/paste/sync settings.
- **RAW decode profiles:** per photo, per camera or global. A camera profile can be fitted to that camera's own JPEGs.

## Releases

Every push to `main` runs the tests on GitHub Actions ([.github/workflows/ci.yml](.github/workflows/ci.yml)).

- **Releasing:** when the push adds a new version section at the top of [CHANGELOG.md](CHANGELOG.md), CI does three things:
  - builds the universal app;
  - tags it `v<version>`;
  - publishes a pre-release that uses that section as its notes.
- **Versions:** fix releases bump the patch (0.1.0 → 0.1.1); significant new features bump the minor (→ 0.2.0).
  - `Tools/changelog.sh next` (or `next minor`) prints the next version.
  - Pushes without a new section only run the tests.
- **Building locally:** `Tools/build_release.sh <version>` makes the same zip in `build/<version>/`.

Signing: releases are signed with the owner's Apple Development certificate when the `SIGNING_CERT_P12` and
`SIGNING_CERT_PASSWORD` repository secrets are set, the same as local builds. If they aren't set, releases
are signed ad hoc.

## Development

- **Building:** open `sloproom.xcodeproj` in Xcode, or see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#build).
- **Tests:** headless checks are compiled from the app sources. See [Tools/README.md](Tools/README.md).
  - `Tools/ci_checks.sh` runs the checks that need no sample photos.
- **Ideas:** see [docs/IDEAS.md](docs/IDEAS.md).
