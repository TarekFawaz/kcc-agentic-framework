---
title: KCC Diagrams
aliases:
  - diagrams
  - kcc-diagrams
tags:
  - framework/documentation
  - kcc/v04
  - diagrams
created: 2026-05-25
updated: 2026-05-25
version: 1.0.0
status: active
---

# KCC Diagrams

Source files for every diagram referenced from the root `README.md`,
`AGENTS.md`, `CLAUDE.md`, and `QUICKSTART.md`.

## Mermaid (text-based, inline in MD)

These render directly in any Markdown viewer that supports Mermaid
(GitHub, Obsidian, VS Code, etc.). Edit the `.mmd` files, then copy the
updated source into the inline mermaid blocks in `README.md`.

| File | What it shows | Used by |
|---|---|---|
| [`kcc-operating-model.mmd`](./kcc-operating-model.mmd) | The full three-layer model: Kernel + Capabilities + Cells with the Inspector learning loop | `README.md` (operating model section) |
| [`kcc-single-cell.mmd`](./kcc-single-cell.mmd) | One repository as one KCC cell: source-of-truth flow into harness outputs with meta-agent backchannel | `README.md` (single cell section) |

## Draw.io (animated / exportable)

`kcc-lifecycle.drawio` is the source file for the **animated lifecycle
GIF** shown in the README header / LinkedIn post / website. It is XML
authored in [draw.io](https://app.diagrams.net) (also distributed as
diagrams.net).

| File | What it shows |
|---|---|
| [`kcc-lifecycle.drawio`](./kcc-lifecycle.drawio) | The 8-stage lifecycle (interrogate to review) with token-budget gates and the always-on meta-agent band |

### How to edit

1. Open [`https://app.diagrams.net`](https://app.diagrams.net) (no
   install needed) or the desktop app from
   [`https://github.com/jgraph/drawio-desktop/releases`](https://github.com/jgraph/drawio-desktop/releases).
2. File -> Open From -> Device -> select `kcc-lifecycle.drawio`.
3. Edit. Save in-place (same `.drawio` filename).

### How to export to an animated GIF

draw.io does not export GIF directly. Use one of these workflows:

#### Option A - Multi-page export plus ffmpeg (highest quality)

1. In draw.io, duplicate the page once per animation step (e.g. 8
   pages: stage 1 highlighted, then stage 1+2, then stage 1+2+3, ...).
   Highlight the active stage with a fill color change on each page.
2. File -> Export As -> PNG -> "All pages". Save each as
   `frame-01.png`, `frame-02.png`, ... in `docs/diagrams/frames/`.
3. Combine into GIF with ffmpeg:

   ```bash
   ffmpeg -framerate 1 -i frames/frame-%02d.png \
     -vf "fps=2,scale=1200:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" \
     docs/diagrams/kcc-lifecycle.gif
   ```

#### Option B - ScreenToGif (Windows, point-and-click)

1. Install [ScreenToGif](https://www.screentogif.com/).
2. Open `kcc-lifecycle.drawio` in draw.io and step through your
   prepared pages manually using arrow keys.
3. Use ScreenToGif's "Recorder" to capture the draw.io window while
   you click through pages.
4. Trim, set frame delays, save as GIF.

#### Option C - drawio-export plus an online GIF maker (cross-platform)

1. Install [drawio-export](https://github.com/rlespinasse/docker-drawio-desktop-headless)
   (headless CLI) and export each page as PNG.
2. Upload PNGs to any GIF maker (e.g.
   [`https://ezgif.com/maker`](https://ezgif.com/maker)) and assemble.

### Conventions

- Output GIFs land at `docs/diagrams/*.gif`.
- Frame intermediates land at `docs/diagrams/frames/` and are
  git-ignored.
- Reference the GIF from the root `README.md` with a relative path:
  `![KCC lifecycle](./docs/diagrams/kcc-lifecycle.gif)`.

## Pending diagrams

These are referenced in the framework but not yet drawn. Open issues
welcome:

- Inspector Pipeline five-stage flow (Observe -> Detect -> Propose ->
  Review -> Promote)
- Cells composition diagram (kernel + selected capabilities + `local/`)
- Backchannel event sequence (a typical brief / estimate /
  approve / remember cycle on `coordination/backchannel.jsonl`)
- Phase Model ladder (Phase 1 -> 2 -> 3 with ceiling annotations)

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](../../LICENSE).
