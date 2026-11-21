# Changelog

Кика is in alpha. Every push to `main` that adds a new section here becomes a GitHub release:
CI builds the universal app and publishes the top section as its release notes (see README → Releases).
Fix releases bump the patch (0.1.0 → 0.1.1); significant new features bump the minor (→ 0.2.0).
Newest first; written for people, not commits.

## 0.7.0 — 2026-11-01

**Instagram story layouts match Instagram's**
- The layouts for story frames are now the ones Instagram's Layout offers, in the same order: a 2 × 2 grid,
  2 stacked, 3 stacked, 1 on top with 2 below (now split in half, as in Instagram), a 2 × 3 grid, and 2 side by side.
  Each photo still exports as its own image in its cell's shape, so it drops straight back into the same cell in
  Instagram.
- Frames you made with the old "1 large + 2 small" layout keep it, but Instagram can't rebuild it any more, so such a
  frame now exports as one finished picture, 1080 × 1920, with the gaps and background as on the board. A ⚠ on the
  frame and its tooltip say so, the Layout menu shows it as old, and the export sheet tells you how many frames were
  saved this way. Pick one of the new layouts to get the photos separately again.

**Quick Look**
- Press Space in the Library to look at the selected photo in a large window, as in Finder. It shows the photo with
  your edits, sized to fit over the main window, with its file name in the title.
- The arrow keys move through the grid while it's open (↑ / ↓ by row; ⇧ extends the selection), and clicking another
  photo in the grid shows that one. Space or Esc closes it; F switches to the full-screen preview; double-click opens
  the photo in Develop.
- Quick Look zooms out of the photo's thumbnail when it opens and back into it when it closes, crossfades from photo
  to photo and resizes to each one's shape, as in Finder. The full-screen preview fades in and out. With Reduce
  motion on (System Settings › Accessibility › Display) it only fades.

**File info**
- Press ⌘I in the Library (or click ⓘ in the toolbar) for an Info panel on the right with the selected photo's file
  name, folder, drive, size, type and pixel size (and the cropped size), when it was taken, the camera, lens,
  exposure and focal length, and when it was imported. With several photos selected it also shows how many and
  their total size. Show in Finder is at the bottom.
- In Develop the same info is in a new Info section at the top of the panel (closed until you open it).

**Masks found on the photo**
- The Masks panel has a new Select row that finds what to mask on your Mac, with Apple's Vision. Nothing leaves the
  Mac.
  - Subject: the people, animals and objects in the photo.
  - Background: everything but the subjects.
  - People: just the people.
  - Sky (beta): the sky above the horizon. Vision has no sky detector, so Кика finds it by colour and position; it
    can take in a pale mountain or miss part of a busy sky, so check it with the overlay.
  - Object: click a subject on the photo to select only it. Add Object adds another one to the same mask; Pick
    Again starts over.
- A new mask is selected with its red overlay on, so you see what was found, and the panel says what it found
  ("1 subject · 24 % of the photo", or "No people found"). Then use the sliders as with any mask; Invert works too.
- The mask is found on the photo itself, not your edits, so changing the exposure or white balance never moves it.
- When you pick an object the pointer turns into a finger, and every object Кика can pick is tinted on the photo, the
  one under the pointer brighter. Picking goes on until Esc: each click adds another object to the mask, ⌥-click
  removes one.
- Expand shrinks or grows what was found (to drop a halo or take in a missed edge) and Feather softens its edge.

**Cleaner masks**
- Any mask can now be built from several shapes. Add ▾ and Subtract ▾ in the selected mask's options add or remove a
  Linear or Radial gradient, the Subject, Background, People, Sky or an object: take the sky out of a gradient, or
  remove a person from Subject. The shapes are listed under the mask; click one to edit it (a gradient gets its
  own handles on the photo), × removes it.
- Brush works on every mask, not just brush masks: turn on Brush, then paint to add to the mask and hold ⌥ to erase,
  with the same Size, Feather and Flow. Use it to clean up what Vision found.
- While painting, the pointer shows + or −, and it turns to − the moment you press ⌥ (before, it kept showing a plus).

**Clean Up: find photos you can remove**
- Library › Clean Up (new in the sidebar) finds photos you may not need. It runs on your Mac with Apple's Vision;
  nothing leaves the Mac and nothing is deleted.
  - Similar shots: shots taken one after another that look alike (a burst, a few tries at the same scene) are
    stacked, like on a phone. The sharpest, best-looking one is marked Best; a photo you picked or rated wins. Click
    shots to mark them Keep or Reject, then press Keep 1, Reject 4 (or Keep All). Double-click a shot for Quick Look.
  - Blurry: the subject is out of focus or shaken. A soft background behind a sharp subject is fine.
  - Cropped subjects: a face cut by the edge of the frame, or a head cut off at the top.
- Run it from Library › Find Photos to Clean Up…, a folder's menu, or the button in Clean Up: on all photos, the
  previous import, or the folders you tick (with their subfolders). Each check has a sensitivity: Only Obvious,
  Balanced or More.
- "Also check photos when importing" (in that window and in the import window's options) runs it after every
  import, so you can clean up right away.
- Keep means "it's meant to look like that": Clean Up never suggests that photo again for that reason, in any later
  run. The Kept tab lists them, and Review Again undoes it. Photos you picked are never suggested.
- Reject flags the photo as rejected. Library › Rejected lists them, ready for Remove from Catalog….
- What Clean Up finds is also kept as tags (Blurry, Cropped, Duplicate), so you can filter by them like any tag.
- Each photo is analysed once; later runs only look at new or edited photos, so they're quick.

**Folders**
- Dragging a folder in the sidebar works again: drag it onto another folder to put it inside, onto the top or bottom
  edge of a folder to reorder, or onto the Folders header to move it to the top level. Before, pressing a folder and
  moving the mouse only changed which folder was selected.

## 0.6.0 — 2026-10-30

**Photos on several devices**
- Keep your library on a photo drive or NAS and still import onto your Mac while you travel. Кика knows which device
  each photo's file is on: This Mac, or a drive, NAS share or card by its name (T9, Photos, …).
- Filter by device: the Filter menu has a new Device section listing every device with its number of photos, and
  "offline" when it isn't connected. Choose one and both the grid and the folder list show only what's on it:
  folders that hold none of its photos are hidden. An "On This Mac" chip shows the filter, and its × clears it. It
  stays on while you move between folders and other sidebar rows. The Folders filter menu has the same section.
- Move to Device…: right-click photos (or choose it in the Photo menu), or right-click a folder and choose Move Photos
  to Device…. Pick the folder they go to, e.g. on your photo drive, and how they're organised there: date folders
  like Import (YYYY/YYYY-MM-DD or YYYY-MM-DD), the same folders they're in now, or all in one folder.
- Each file is copied, and the copy is compared byte for byte with the original before Кика switches to it. Edits,
  flags, ratings, tags, folders, virtual copies and previews all stay with the photo. RAW + JPEG pairs move together.
- Tick "Move the originals to the Trash" to free up space on your Mac once the copies are checked. It's off every
  time you open the sheet, so originals are only removed when you ask.
- Both devices need to be connected. Photos on a drive that isn't connected are listed and skipped.
- Nothing is overwritten: a different file with the same name in the destination gets "-1" added. An identical file
  that is already there (e.g. from a move you stopped) is used as it is. Stopping a move keeps every photo moved so
  far, and the one in progress stays where it was.

**Folders**
- Right-click a folder and choose Move To ▸ to put it into another folder, or back at the top level. Dragging
  still works too.

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
