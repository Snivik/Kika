# Changelog

Кика is in alpha. Every push to `main` that adds a new section here becomes a GitHub release:
CI builds the universal app and publishes the top section as its release notes (see README → Releases).
Fix releases bump the patch (0.1.0 → 0.1.1); significant new features bump the minor (→ 0.2.0).
Newest first; written for people, not commits.

## 0.5.0 — 2026-10-19

**Export for Instagram**
- Save your planned posts and stories as images ready to upload. Right-click a slide and choose Export Slide…,
  choose Export Post… or Export Stories… in a card's ⋯ menu, or click Export Plan… above the plan (or right-click
  the plan in the sidebar). Pick a folder and the images are saved there. Posted cards can be exported too.
- Every photo becomes its own image, 1080 px wide, with your Develop edits and cropped exactly as you framed it on the
  board. A single-photo slide comes out in the post's shape (1080 × 1350 for 4:5). A split gives one image per
  carousel slide. A layout never turns into one combined picture: a frame with 3 photos gives 3 images, each in the
  shape of its cell, so you can put them together in Instagram's own layout.
- Each post gets a folder named after it, with the images and a post.txt: the caption exactly as you wrote it,
  hashtags included, ready to paste, and below it the planned date and the status. Stories have no caption, so
  their folder holds only the images.
- Export Plan… gives every post and set of stories its own folder, numbered in board order: "01 Post 1",
  "02 Stories 1", and so on.
- Files are numbered in posting order: 01.jpg, 02.jpg, …, matching the slide numbers on the board. The images of one
  slide share its number: 03-1.jpg, 03-2.jpg, … from left to right for a split, and by cell (top to bottom, left to
  right) for a layout. They sort in that order in Finder and in upload pickers.
- Where a photo is scaled smaller than its cell, the frame's background colour fills the rest, as on the board.
  Narrow cells keep their shape too, so the halves of a side-by-side story frame come out tall (1080 × 3953).
- Nothing is overwritten: exporting a post again creates "Post 1 (2)". Photos whose drive isn't connected are
  skipped and listed when the export finishes.

**Fixes**
- Skimming through photos with the arrow keys in Develop or Full Screen Preview no longer leaves a backlog of
  renders behind you. Photos you pass show their cached preview. Only the photo you stop on is read and rendered
  in full, and it starts right away instead of waiting its turn. A new setting, **Full preview delay** (Settings →
  Previews, 0.5 s by default), sets how long you have to stay on a photo before it renders in full. (#1)
- The Adjust Photos sheet now fits inside a small window. Before, its Cancel and Done buttons could hang off the
  bottom edge. (#4)
- The preview progress ring in the toolbar no longer touches the edge of its capsule. (#3)
- Switching folders in the Library grid starts the new folder at the top, with the selected photo scrolled into
  view. This should stop the day header (By Date) from showing up over the middle of the first row. (#6)
- In Develop, choosing a folder that doesn't contain the open photo now opens that folder's first photo, instead of
  leaving the old photo on screen. (#7)
- A drag that never finished (seen on the Instagram board) could leave an invisible window over the screen, so
  left clicks stopped working anywhere in Кика until another drag. Кика now notices this on your next click and
  removes that window: one click does nothing, then everything works again. Each time it happens it's logged, to
  help find the cause. (#2)

## 0.4.0 — 2026-10-18

**Instagram Planner**
- Right-click a folder and choose New Instagram Plan. An Instagram row appears under the folder. It shows the
  folder's photos next to your posts and stories, so you can arrange 20–30 picks into a few posts and stories.
- Drag photos onto a post or a set of stories. Drop on the edge of a slide to insert, in the middle to replace,
  or on the last slot to add at the end. Drag slides to reorder them, also from one post to another.
- Posts are carousels of up to 20 slides in 4:5, 3:4 or 1:1, with a caption (with a character count and Copy
  Caption), a planned date and a status: Draft, Ready or Posted. Posted ones are locked.
- Story frames can hold one photo or a layout: 2 stacked, 2 side by side, 3 stacked, a 2 × 2 grid, or 1 large +
  2 small, on a white, black, cream or gray background.
- Split a photo across 2–5 carousel slides so it scrolls as one panorama.
- Adjust Photos (double-click a slide, or right-click it) opens the slide large. Each photo of a layout, or a split's
  photo with its frame and cut lines as a guide, can be moved, scaled with its corner handles and rotated with the
  handle above it, or with the sliders, quarter turns, Fill and Fit. The part of the photo outside the frame shows
  faded, and a warning appears when the background would show. Nothing changes until you click Done.
- A Calendar (in the sidebar's Library section, or Calendar on a plan) shows every plan's posts and stories
  on a month calendar by planned date, with the first photo, time and status. Filter by Posts, Stories or both, and
  hide what's posted. Drag one to another day to reschedule it, or onto Not Scheduled to clear its date. Click one to
  open it in its plan.
- Every photo used in a post or story shows a badge in the grid (P1, S2, …), and the Filter menu has Instagram:
  Not Used and Used, so you can see which picks are left.
- Exporting posts and stories as ready-to-upload images, and reminders when it's time to post, will come in a
  later release.

## 0.3.0 — 2026-10-13

**Sloproom is now Кика**
- The app has a new name, Кика ("Kika"), after the horned headdress women wore in old Russia, and a new icon:
  a kika drawn in red marker.
- To macOS, Кика is a different app from Sloproom, so it starts with an empty catalog and default settings. To
  bring your photos over, choose File › Export Catalog… in Sloproom, then File › Import Catalog… in Кика, and
  grant access to your folders and drives again when it asks. After that you can delete Sloproom.
- Catalog exports are now `.kikacatalog` files and decode profiles `.kikadecode`. Кика still opens
  `.sloproomcatalog` and `.sloproomdecode` files.
- The download is now called `Kika-<version>-alpha-universal.zip`.

## 0.2.0 — 2026-10-12

**Tags**
- Tag photos and folders. A tag has a name, a colour and a list of values: true / false for yes-or-no
  questions like Blurry, or your own choices like Anna / Ben.
- Each value remembers who set it: you, or a workflow. Your value always wins. Values a workflow suggested and
  you haven't looked at yet are grouped under To Review, so you can check a small set instead of every photo.
- The sidebar lists every tag with its values and counts. Tagged photos and folders show coloured dots:
  filled when you set the value, a ring when it's a suggestion.
- Set tags from the right-click menu, the Photo menu or the new Tags panel in Develop, where you can also confirm
  suggestions one photo at a time.
- Folders show their tags as small circles after the name, like Finder. A filter at the top of the folder list
  narrows it by name or tag, keeping each match's parent folders for context.

**Sidebar**
- New Dates section: every year and month you took photos in, with counts, whatever folders they're in.
- Hide any sidebar section with the arrow in its header (Library, Folders, Dates, Tags); Sloproom remembers which
  are hidden.

**Filtering**
- One Filter menu for flags, star ratings and tags, in Library and in Develop's filmstrip. Active filters show
  as chips you can remove with one click.
- Filter any tag by "Untagged" to find photos or folders nobody has tagged yet, e.g. ones a workflow hasn't
  looked at.

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
