# PDF Layout

A minimal native macOS app for arranging images, text, and lines on pages and exporting as PDF. One Swift file, no Xcode project, no dependencies.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-single%20file-orange) ![Dependencies](https://img.shields.io/badge/dependencies-none-green)

## Features

### Canvas & Navigation
- **Figma-like free canvas** — two-finger trackpad scroll to pan in any direction
- **Pinch to zoom** with centered zoom (0.25x–4x range)
- **Zoom controls** — fit width, fit page, actual size via menu or shortcuts
- **Zoom percentage overlay** with auto-fade

### Images
- **Paste** from clipboard (⌘V) or **drag & drop** from Finder
- **Resize from all four corners** — aspect ratio locked by default, Option-drag for free resize
- **Double-click to replace** an image with a new file
- **Rotate** — ⌘R for 90° steps, trackpad for free rotation with haptic detents
- **Opacity slider** (5–100%)
- **Frame options** — customizable color and width
- **Pinch to resize** selected image

### Text
- Click to place, **double-click to edit** inline
- **Font size**, **color**, **bold**, and **italic** controls in toolbar
- Resize text from any corner handle
- Rotate via mouse handle or trackpad gesture

### Lines
- Click and drag to draw with **smooth magnetic H/V pull**
- Shift to lock to horizontal or vertical
- **Double-click** to extend to full page width/height
- **Drag endpoints** to reshape after drawing
- Adjustable color and line width

### Pages
- **A4** and **US Letter** page sizes
- **Portrait / landscape** toggle (⌘L)
- Add and remove pages (⌘N / ⌘⇧N)
- Continuous vertical scroll across multiple pages

### Alignment & Organization
- **Smart snap guides** — elements snap to edges, centers, and page boundaries
- **Grid overlay** toggle (⌘G) — visible on screen, not in PDF
- **Bring to front** (⌘]) / **send to back** (⌘[)
- Selected elements automatically move to front

### Editing
- **Undo / redo** (⌘Z / ⌘⇧Z) with 50-step history
- **Duplicate** any element (⌘D)
- **Arrow key nudge** — 1pt per press, 10pt with Shift
- **Background color** — white, gray, cream, or black

### Export
- **Save as multi-page PDF** (⌘S)
- **Open existing PDFs** (⌘O) — imports pages as images

## Install

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/mehmetmertaktas/pdflayout.git
cd pdflayout
./build.sh
```

This creates **PDF Layout.app** in the current directory. Move it to `/Applications` or double-click to run.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘V | Paste image from clipboard |
| ⌘O | Open PDF file |
| ⌘S | Save as PDF |
| ⌘D | Duplicate selected element |
| ⌘R | Rotate 90° clockwise |
| ⌘B | Toggle frame on image |
| ⌘L | Toggle landscape / portrait |
| ⌘G | Toggle grid overlay |
| ⌘] | Bring to front |
| ⌘[ | Send to back |
| ⌘Z | Undo |
| ⌘⇧Z | Redo |
| ⌘N | Add page |
| ⌘⇧N | Remove last page |
| ⌘= | Zoom in |
| ⌘- | Zoom out |
| ⌘0 | Zoom to fit width |
| ⌘⇧0 | Zoom to fit page |
| ⌘1 | Actual size (1:1) |
| ←→↑↓ | Nudge 1pt |
| ⇧ + ←→↑↓ | Nudge 10pt |
| Delete | Remove selected element |

## Trackpad Gestures

| Gesture | Action |
|---------|--------|
| Two-finger scroll | Pan canvas freely |
| Pinch (nothing selected) | Zoom canvas |
| Pinch (item selected) | Resize selected element |
| Two-finger rotate | Rotate selected element |

## How It Works

One Swift file (`pdflayout.swift`), compiled with a shell script. No Xcode project, no dependencies, no package managers. Uses AppKit for the UI and PDFKit for export. All elements live in page coordinate space (595 × 842pt for A4, 612 × 792pt for Letter) and are scaled to the screen for resolution-independent layout. The app icon is procedurally generated at build time.
