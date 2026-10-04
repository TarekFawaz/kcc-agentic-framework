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

## Draw.io (animated hero)

`kcc-lifecycle.drawio` is the source of the **animated GIF** at the top of
the root README. It has one page per animation step (19 pages). Every page
holds the same shapes; only the colours differ: grey = waiting, strong
colour = active now, pale colour = done.

| File | What it shows |
|---|---|
| [`kcc-lifecycle.drawio`](./kcc-lifecycle.drawio) | Set up once (`kcc` install, init, tailor, harness adapters), the meta-agent band, the ten-step lifecycle with budget gates through merge and deploy, the scripted exit checks, auto-continue on usage limits, and the learning loop |
| [`kcc-lifecycle.gif`](./kcc-lifecycle.gif) | The pages above played in order |
| [`make-lifecycle.ts`](./make-lifecycle.ts) | Generator for both files |

### How to change it

The layout, texts, colours, and step order are plain data at the top of
`make-lifecycle.ts`. Edit them, then regenerate:

```bash
bun run docs/diagrams/make-lifecycle.ts          # rewrites kcc-lifecycle.drawio
bun run docs/diagrams/make-lifecycle.ts --gif    # also exports every page and rebuilds the GIF
```

`--gif` needs the [draw.io desktop app](https://github.com/jgraph/drawio-desktop/releases)
(set `DRAWIO` to its executable if it is not in the default install
location) and `ffmpeg` on PATH. It exports each page to PNG with the draw.io
command line and joins the frames with ffmpeg.

You can also open `kcc-lifecycle.drawio` in draw.io and edit pages by hand,
but the next run of the generator overwrites hand edits. For a lasting
change, edit the generator.

### Exporting by hand

1. `draw.io --export --format png --page-index <n> --width 1600 --output frames/frame-<nn>.png kcc-lifecycle.drawio`
   for each page.
2. Join the frames:

   ```bash
   ffmpeg -framerate 1.3 -i frames/frame-%02d.png      -vf "fps=10,scale=1456:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"      kcc-lifecycle.gif
   ```

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
