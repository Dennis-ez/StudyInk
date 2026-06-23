# Inkling — Web Engineering Handoff (v2.0)

> Single source of truth for rebuilding Inkling's **web** frontend (React + TypeScript + Tailwind).
> This document is written to be executed literally. Where the build keeps drifting (floating sidebars,
> loose spacing, vague mechanics), this closes the gap with exact CSS, exact constraints, and an
> architecture that makes the wrong implementation hard to write.
> Primary build target: **iPad Pro 12.9″ landscape — 1366×1024 CSS px**. Verify there first.

## The 8 non-negotiables
1. The sidebar is a **CSS Grid track** — full-bleed, `100dvh`, flush at x=0. Never floating/absolute/margined.
2. The editor header is **compact (44px) & auto-hiding** — it must not eat canvas height.
3. Every color is a **CSS variable token**. Zero hardcoded hex in components.
4. The writing surface (`--paper`) and note thumbnails are **never theme-tinted**.
5. Layout uses **logical properties** (`inline-start`, `padding-inline`) so RTL mirrors for free.
6. Every flex/grid child that can shrink gets `min-width:0`.
7. The AI bubble is a **compact card**, not a panel.
8. Build via **subagents** against shared tokens — never re-style primitives per screen.

## Locked tech stack
- **Framework:** React 18 + TypeScript, Vite
- **Styling:** Tailwind CSS v4 (`@theme`, CSS-first) + token CSS variables
- **State:** Zustand (3 stores) + `localStorage` persist
- **Motion:** Framer Motion (springs) + CSS for micro-states
- **Icons:** **Lucide React** (exact names given per control)
- **Math:** KaTeX (`react-katex`)
- **Canvas:** `perfect-freehand` on `<canvas>`/SVG ink
- **A11y primitives:** Radix (Popover, Dialog, Slider, Tabs) — **restyled to tokens, not default**

---

# 1. Global Layout & Structural Architecture (The Shell)

The shell is one **CSS Grid**, full-viewport, that never scrolls as a whole. Exactly one descendant scrolls at a time. Build and verify this skeleton before any screen content.

## 1.0 The app shell — one grid, fixed viewport
```css
.app-shell {
  display: grid;
  grid-template-columns: var(--sidebar-w, 264px) minmax(0, 1fr); /* minmax(0,1fr) prevents blowout */
  grid-template-rows: 100dvh;   /* dvh, NOT vh */
  width: 100vw; height: 100dvh;
  overflow: hidden;             /* the shell itself never scrolls */
  background: var(--bg-desk);
}
.app-shell[data-collapsed="true"] { --sidebar-w: 0px; }
.app-shell[data-rail="true"]      { --sidebar-w: 64px; }
```
**Why grid, not flex + floating aside:** a grid *track* is structurally part of layout — the content column is mathematically `100vw − var(--sidebar-w)` and can never be overlapped. The "floating sidebar" failure happens when the sidebar is `position:fixed/absolute` and content gets a manual margin. **Forbidden.** Sidebar has no margin, no radius, no shadow, no inset — only a 1px trailing border.

## 1.1 Sidebar — full-bleed, 100dvh, resizable, collapsible
| Property | Spec |
|---|---|
| Position | Grid column 1, pinned x=0→bottom, `height:100dvh` |
| Default width | `264px` (`--sidebar-w`) |
| Resizable | Yes. Trailing drag handle. Clamp `220–360px` |
| Drag handle | `6px` hit-zone, `cursor:col-resize`; 1px border → 2px + `--you` on hover/drag |
| Double-click handle | Reset to `264px` |
| Collapsible | Two-stage: full → 64px rail → 0. `⌘\` toggles. Persisted |
| Background | `--bg-sidebar`, 1px trailing border, no shadow/radius |
| Internal scroll | Only nav list scrolls; wordmark + Settings pinned |
| Padding | inline `12px`, block `14px` |

```css
.sidebar {
  grid-column: 1; height: 100dvh;
  display: flex; flex-direction: column;        /* Settings pins via margin-top:auto */
  background: var(--bg-sidebar);
  border-inline-end: 1px solid var(--border);   /* logical → mirrors in RTL */
  padding-block: 14px; padding-inline: 12px;
  overflow: hidden; position: relative;         /* anchors resize handle only */
}
.sidebar__scroll { flex:1 1 auto; overflow-y:auto; min-height:0; }
.sidebar__resize-handle {
  position:absolute; inset-block:0; inset-inline-end:-3px; width:6px;
  cursor:col-resize; z-index:5; touch-action:none;
}
```
Structure top→bottom: **wordmark (pinned)** · search field · **scroll region** (Smart: All/Recents/Favorites · divider · SUBJECTS nestable color-dot rows · divider · Recently Deleted) · **Settings (pinned, margin-top:auto)**.
Resize is driven by `useSidebarResize()` — writes `--sidebar-w` via rAF during drag, persists on pointer-up. **Never** store width in React state during drag.

## 1.2 Headers — context-specific, never obscuring
**A · Library header:** height `56px`, `position:sticky;top:0` inside content scroll, `--bg-chrome`@78% + `backdrop-blur(16px)`, 1px bottom border on scroll only, lives **inside** content column (never spans sidebar), z `40`.

**B · Editor header (the fix):** height **`44px`** only, transparent + blur (canvas shows through), auto-hides on scroll-down (`translateY(-100%)`, 200ms), reveals on scroll-up or pointer within 8px of top. Leaves a **3px peek** + 28px floating title chip when hidden. Absolutely positioned over canvas (z `40`) → **zero layout height cost.**
```css
.editor-header {
  position:absolute; inset-block-start:0; inset-inline:0; height:44px; z-index:40;
  display:flex; align-items:center; gap:12px; padding-inline:16px;
  background: linear-gradient(var(--bg-chrome-a70), transparent);
  backdrop-filter: blur(12px) saturate(140%);
  transform: translateY(var(--header-shift, 0));   /* 0 or -100% from hook */
  transition: transform .2s cubic-bezier(.22,1,.36,1);
}
```
Decision rule: accumulate scroll delta, flip only when `|Δy| > 6px`; down→hide, up→show; always show when `scrollTop < 12`. Under `prefers-reduced-motion`, header stays pinned and just goes translucent.

## 1.3 Main content canvas — flex column, single scroll owner
```css
.content {
  grid-column: 2;
  min-width: 0;            /* THE most important line in the shell */
  display:flex; flex-direction:column; height:100dvh; overflow:hidden;
  background: var(--bg-chrome);
}
.content__scroll { flex:1 1 auto; overflow-y:auto; overscroll-behavior:contain; } /* library */
.editor-stage   { position:relative; flex:1 1 auto; min-height:0; overflow:hidden; } /* editor: canvas + overlays */
```

## 1.4 Editor sub-shell (inside `.editor-stage`)
| Layer | Placement | Drag/resize | z |
|---|---|---|---|
| Notes pane (mini-library) | Leading drawer 236px, push (canvas reflows) | collapse only | 20 |
| Page canvas | Fills remaining; pans/zooms internally | pan/zoom content | 1–3 |
| Page-thumb strip | Trailing in-flow column 76px, own scroll | reorder (dnd) | 20 |
| Floating toolbar | Draggable, docks any edge; default top-center | **draggable + edge-snap** | 30 |
| Options strip | Attached to toolbar's docked side | moves with toolbar | 30 |
| Editor header | Overlay, auto-hide (§1.2B) | static | 40 |
| AI bubble | Anchored to circled region | **draggable** (re-anchors tail) | 50 |
| AI side panel | Trailing drawer 320px | static; resizable 300–420 | 60 |
| Sheets / modals | Centered/bottom, scrim 40% | static | 70 |
| Toasts / loading | Top-center stack | static | 80 |

## 1.5 z-index contract & responsive
```css
--z-canvas:1; --z-ink:2; --z-ai-marks:3; --z-rail:20; --z-toolbar:30;
--z-header:40; --z-bubble:50; --z-panel:60; --z-modal:70; --z-toast:80; --z-theme-x:90;
```
Never write a raw z-index in a component.
Responsive: ≥1280 sidebar expanded · 1024–1279 auto-collapse to 64px rail (hover/tap to overlay) · 768–1023 sidebar overlay drawer + scrim, single-column grid · <768 off-canvas, header menu button. The shell swaps `grid-template-columns` + a `data-overlay` attr; the sidebar component never changes.

---

# 2. Design Tokens & Theme Variations

One token contract; four very different skins. `useTheme()` sets `data-theme` + `data-mode` on `<html>` and the whole app re-skins. Components reference **semantic** tokens only.

## 2.0 Token architecture
Three layers: **primitives** (raw, never used directly) → **semantic** (the only thing components touch) → **theme attributes** on `<html>` rebind the semantic layer.
```
<html data-theme="foolscap" data-mode="light" dir="ltr">
```
Semantic color tokens (every theme defines all): `--bg-desk`, `--bg-sidebar`, `--bg-chrome`, `--surface`, `--surface-2`, `--paper`🔒, `--border`/`--border-strong`, `--text`, `--text-muted`, `--text-radiant`, `--primary`/`--primary-soft` (you+ink), `--secondary`/`--secondary-soft` (AI), `--success`, `--destructive`, `--ai-hi`/`--ai-circle`/`--ai-arrow`/`--ai-underline`.

## 2.1 Scales (theme-agnostic)
**Typography** (rem-based off 16px root → scales with OS/browser font-size):
| Role | Family | Size/Wt | LH | Scales? |
|---|---|---|---|---|
| display-xl | Fraunces | 28/600 | 1.05 | yes |
| display | Fraunces | 22/600 | 1.1 | yes |
| title | Fraunces | 20/600 | 1.15 | yes |
| heading | System | 17/600 | 1.3 | yes |
| body | System | 16/400 | 1.5 | yes |
| callout | System | 15/450 | 1.35 | yes |
| chip | System | 13/500 | 1.2 | yes |
| caption | System | 13/400 | 1.3 | yes |
| micro-label | System | 11.5/700 | 1.2 | **no** (uppercase .1em) |
| mono | SF Mono | 12–13/500 | 1.4 | yes |

Display = Fraunces (bundled brand serif). System = `-apple-system, "SF Pro Text", system-ui, "Segoe UI", sans-serif`. Fixed (non-scaling): tool glyphs, page numbers, swatch/size dots, micro-labels.

- **space:** 2·4·8·12·16·20·24·32·40·48·64
- **radius:** sm8·md12·lg16·xl20·card14·pill999 (theme-tunable, see 2.6)
- **stroke:** hairline1·thin1.5·regular2·thick3
- **ink width:** XS1.5·S2.5·M4·L7·XL10·highlighter18
- **elevation (light ref):** e0 none(border only) · e1 `0 1px 2px /6%` cards · e2 `0 8px 24px -6px /14%` toolbar/popover · e3 `0 18px 44px -10px /22%` bubble/sheet. Shadow color is per-theme.

## 2.2 The four themes (🔒 = `--paper`, never changes within a mode)

### Theme 1 — Foolscap (refined default) — warm paper, navy ink, amber tutor
**Light:** primary `#2E4057` (8.9:1) · secondary `#B5762A` (3.6:1) · bg-desk `#E7DECB` · bg-sidebar `#EFE7D7` · bg-chrome `#F6F0E4` · surface `#FCFAF5` · surface-2 `#F0E8D8` · paper `#FCFAF5`🔒 · border `#E0D6C2` / strong `#D2C5AC` · text `#2B2722` (11:1) · text-muted `#8A8073` · text-radiant `#14110D`
**Dark:** primary `#7FB0E8` · secondary `#D9A24E` · bg-desk `#15130F` · bg-sidebar `#1E1B15` · bg-chrome `#232019` · surface `#2A261E` · surface-2 `#322D24` · paper `#1A1814`🔒 · border `#38332B` · text `#F2ECE0` · text-muted `#9A9082` · text-radiant `#FFFFFF`
**State/AI:** success `#6B8E4E` · destructive `#C0392B` · hi `#FFD60A@38%` · circle `#FF9F0A` · arrow `#6B8E4E` · underline `#2E4057`. Radius soft (card14, bubble18). Shadow warm-black.

### Theme 2 — Neon (cyberpunk, dark-native) — near-black glass, glowing cyan/magenta
**Dark (native):** primary `#22D3EE` cyan (9.2:1) · secondary `#F062E8` magenta · bg-desk `#07070C` · bg-sidebar `#0B0B12` · bg-chrome `#0E0E17` · surface `#14141F` · surface-2 `#1B1B29` · paper `#101019`🔒 · border `#232338` / strong `#34344F` · text `#E6E8F2` (14:1) · text-muted `#7C7F9E` · text-radiant `#FFFFFF`
**Light (contrast-safe fallback):** primary `#0E97B0` · secondary `#B0249E` · bg-desk `#EAECF4` · bg-sidebar `#F4F5FA` · bg-chrome `#FFFFFF` · surface `#FFFFFF` · paper `#FFFFFF`🔒 · border `#E2E3EE` · text `#15151F` · text-muted `#6A6D86` · text-radiant `#000000`
**State/AI (dark):** success `#2BF5A0` · destructive `#FF3B6B` · hi `#F5F021@28%` · circle `#FF7AC6` · arrow `#2BF5A0` · underline `#22D3EE`. Shadow = colored glow `0 0 0 1px accent, 0 0 18px accent/45%`. Radius card10.

### Theme 3 — Daylight (premium, light-native) — crisp white, sharp borders, indigo
**Light (native):** primary `#3B5BFF` (6.1:1) · secondary `#7C3AED` violet · bg-desk `#EEF0F4` · bg-sidebar `#F7F8FA` · bg-chrome `#FFFFFF` · surface `#FFFFFF` · surface-2 `#F2F4F7` · paper `#FFFFFF`🔒 · border `#E3E6EC` / strong `#CDD2DB` · text `#0F172A` (16:1) · text-muted `#64748B` · text-radiant `#000000`
**Dark:** primary `#6488FF` · secondary `#A78BFA` · bg-desk `#0B0D12` · bg-sidebar `#0F1219` · bg-chrome `#11141B` · surface `#161A22` · surface-2 `#1E232D` · paper `#14171E`🔒 · border `#232A35` · text `#E7EAF0` · text-muted `#8B95A7` · text-radiant `#FFFFFF`
**State/AI:** success `#16A34A` · destructive `#E11D48` · hi `#FFE45C@45%` · circle `#F59E0B` · arrow `#16A34A` · underline `#3B5BFF`. Borders are the hero (sharp 1px), minimal shadow. Radius card10.

### Theme 4 — Graphite (e-ink monochrome) — no hue; ink & paper only
**Light (e-ink paper):** primary `#1A1A1A` ink (15:1) · secondary `#5A5A52` graphite · bg-desk `#E8E8E4` · bg-sidebar `#F2F2EE` · bg-chrome `#FAFAF7` · surface `#FFFFFF` · surface-2 `#F0F0EC` · paper `#FCFCFA`🔒 · border `#D8D8D2` / strong `#B8B8B2` · text `#141414` · text-muted `#76766E` · text-radiant `#000000`
**Dark (slate):** primary `#EDEDED` · secondary `#ABABAB` · bg-desk `#161616` · bg-sidebar `#1C1C1C` · bg-chrome `#202020` · surface `#262626` · surface-2 `#2E2E2E` · paper `#1B1B1B`🔒 · border `#353535` · text `#ECECEC` · text-muted `#9A9A9A` · text-radiant `#FFFFFF`
**State/AI:** success & destructive map to `--text` — distinguished by **fill vs outline + glyph**, never hue. AI marks are **dashed/dotted** ink (user ink solid): hi `#000@9%` block · circle `#1A1A1A` dotted · arrow `#1A1A1A` · underline `#1A1A1A`. Shadow = none (e0, borders only). Radius crisp 4–6.

## 2.6 Theme definition in code
```css
/* themes.css */
[data-theme="foolscap"][data-mode="light"] {
  --bg-desk:#E7DECB; --bg-sidebar:#EFE7D7; --bg-chrome:#F6F0E4;
  --surface:#FCFAF5; --surface-2:#F0E8D8; --paper:#FCFAF5;
  --border:#E0D6C2; --border-strong:#D2C5AC;
  --text:#2B2722; --text-muted:#8A8073; --text-radiant:#14110D;
  --primary:#2E4057; --primary-soft:#DDE2E9;
  --secondary:#B5762A; --secondary-soft:#EFE2CC;
  --success:#6B8E4E; --destructive:#C0392B;
  --ai-hi:rgba(255,214,10,.38); --ai-circle:#FF9F0A; --ai-arrow:#6B8E4E; --ai-underline:#2E4057;
  --radius-card:14px; --shadow-e2:0 8px 24px -6px rgba(40,34,28,.14);
}
[data-theme="graphite"] {            /* shape overrides apply to both modes */
  --radius-card:6px; --radius-md:6px;
  --shadow-e1:none; --shadow-e2:0 0 0 1px var(--border); --shadow-e3:0 0 0 1px var(--border-strong);
}
[data-theme="neon"][data-mode="dark"] {
  --shadow-e2:0 0 0 1px var(--primary), 0 0 18px color-mix(in srgb, var(--primary) 45%, transparent);
}
```
```ts
type ThemeName = 'foolscap' | 'neon' | 'daylight' | 'graphite';
type Mode = 'light' | 'dark' | 'system';
// useTheme() writes documentElement.dataset.theme/mode + persists. 'system' via matchMedia, reactive.
```
**Theme-switch motion:** snapshot to a fixed full-screen layer (`--z-theme-x`) and crossfade old paint out over 220ms while new tokens apply underneath — avoids the harsh multi-color rebind flash. Skip under `prefers-reduced-motion`.

---

# 3. Screen-by-Screen Component Spec

Treatment legend: *Flat* = bg + 1px border, no shadow · *Elevated* = surface + e1/e2/e3 · *Inset* = `--surface-2` recessed. Icons are **Lucide** names. Values are CSS px @ 1366×1024. `p:`padding `r:`radius `h:`height `g:`gap.

## 3.1 Library / Home
**Sidebar rows:** wordmark (h44, 26px logo r7 `--primary` + 10px `--ai-circle` dot + "Inkling" display/20 + collapse btn Lucide `panel-left-close`) · search (inset h38 r10 `--surface-2`, Lucide `search` + "Search notes" + `⌘K` chip; states default/focus[2px `--primary` ring]/typing) · smart rows (h40 r9 g11, Lucide `layers`/`clock`/`star` 19 + callout/15 + count; states **default**=transparent / **selected**=`--primary-soft` + 3px `--primary` leading bar + label600 / **pressed**=`--surface-2` / hover) · "SUBJECTS" micro-label · subject rows (h36 r9, 11px r3 color dot + label + count, nestable: child indent +18px + Lucide `chevron-right`/`chevron-down`; states +drag-reorder ghost@60% + 2px `--primary` drop line) · Settings (pinned bottom, Lucide `settings`).

**Content:** header (H1 "All notes" display-xl/28; right cluster g10: **Ask AI** pill h38 r-pill `--primary` + Lucide `sparkles` + radiant · Import 38 circle Lucide `file-up` · Overflow 38 circle Lucide `more-horizontal` · New note 38 circle `--primary` Lucide `square-pen` radiant) · filter tabs (pills g8, active=`--text` bg/`--bg-chrome` text, rest `--surface-2`+border; right "Sorted by date" + Lucide `arrow-up-down`) · **note card** (Elevated e1, r14 `--surface` 1px `--border`; cover h196 = paper thumbnail using `--paper` NOT themed; footer p12 name heading/15/600 ellipsis + 9px subject dot + date caption; states default / hover[lift -2px, e2] / pressed / selected[2px `--primary` ring] / **loading**[cover shimmer `--surface-2`→`--bg-chrome` 1.4s + 2 skeleton bars] / menu-open[overflow ⋯ top-right on hover]) · grid (`repeat(auto-fill, minmax(248px,1fr))` g20 p22/34, 3 cols at target) · empty (centered Lucide `sparkles` in 56 circle + "No notes yet. Tap + to start." `--text-muted`).
Draggable/resizable: subject rows (reorder+nest), cards (drag to subject), sidebar width. Else static.

## 3.2 Note Editor
- **Header (§1.2B):** compact 44 transparent+blur auto-hide. Leading Lucide `chevron-left` (32 r8). Title block: name title/18/600 (tap→inline rename) + "Calculus I · Edited 2m ago" caption. Trailing: Lucide `share` · `copy`(pages) · **Tutor** pill (`--secondary`, Lucide `sparkles`).
- **Canvas:** `--paper` base, template via repeating-linear-gradient (§3.5). Ink renders **light-on-dark** in dark mode; paper stays its own surface. Pan/zoom internal. States idle/drawing/selection-active.
- **Floating toolbar:** Elevated e2, pill r-pill `--surface`@96%+blur 1px border, h52. Groups (1px dividers): `[grip]` · undo redo │ pen tools │ eraser lasso hand │ accessories │ overflow. 40×40 hit each. **Active** = filled `--primary` circle + radiant glyph. **Draggable + docks to any edge** (snap spring). States default/hover/active/disabled.
- **Options strip:** Elevated, attaches to toolbar's docked side, r16, same material, swaps per active tool (§3.3). Moves with toolbar.
- **Page-thumb strip:** Flat in-flow column 76 `--bg-chrome` own scroll. 48×62 ruled mini-thumbs, current = 2px `--primary` border + number caption. Dashed "+ add page" (Lucide `plus`). **Reorder dnd**; long-press→duplicate/delete.
- **Notes pane:** Leading drawer 236 push layout, mini list, collapsible (Lucide `panel-left`).
- **Page indicator:** bottom-center pill "3 / 7" `--surface`@88%+blur caption.

**Toolbar tool → Lucide:** pen `pen` · fountain `pen-tool` · monoline `pen-line` · highlighter `highlighter` · pencil `pencil` · eraser `eraser` · lasso `lasso` · hand `hand` · ruler `ruler` · text `type` · AI pen `wand-sparkles` · AI history `history` · undo/redo `undo-2`/`redo-2` · image `image` · overflow `more-horizontal` · audio `mic` · shapes `shapes` · grip `grip-vertical`.

## 3.3 Options strip & on-page objects
- **Pen/pencil/fountain:** current-color swatch 28 · 8 swatches 24 (selected=2px paper+2px `--primary` ring) · custom `+` · divider · 4 stroke dots (4/7/10/14) · divider · **Pressure** toggle.
- **Highlighter:** +blend toggle (Normal/Multiply), widths 10/14/18/24.
- **Eraser:** segmented Object/Pixel · size slider · "Erase whole page" (`--destructive` text).
- **Lasso:** segmented Free/Rect · content filter chips (ink/text/images).
- **Color picker (full):** popover HSB area + hue + opacity rails · hex field mono · eyedropper (Lucide `pipette`) · 6 recents.
- **Text box:** font list · size stepper · B/I/U/S (Lucide `bold`/`italic`/`underline`/`strikethrough`) · color · align (Lucide `align-left`/`center`/`right`, RTL-aware).

On-page objects: text box (focus=dashed `--primary` 1.5 + 8 handles, draggable+resizable) · image (r8, select=border + 8 handles + rotate, draggable+resizable) · audio bar (flat pill `--surface`, Lucide `mic` + waveform + timer + play/stop, docks bottom-left, states recording[pulsing `--destructive` dot]/playing/idle) · shape (vector stroke in current ink, draggable+resizable).

## 3.4 The AI Bubble — absolute redline
Compact card anchored to the circled region, speech tail pointing at it. **Not a panel.**
| Part | Spec |
|---|---|
| Container | **w304** (300–320), height hugs content. `--surface`@88% + `backdrop-filter:blur(20px) saturate(160%)`. r18, 1px `--border`, shadow e3 |
| Tone strip | **4px** full-height `inset-inline-start:0`. teaching `--primary` / correct `--success` / correction `--ai-circle` / error `--destructive` |
| Padding | block13, inline-end15, **inline-start18** (clears strip) |
| Top row | 22 circle avatar (`--secondary`, Lucide `sparkles` radiant) + "Inkling Tutor" caption `--text-muted` + trailing Lucide `x` 16. g8 |
| Body | body/16 `--text`, max ~4 lines → "Show more". Referenced term = `--ai-hi` pill. Math = inline KaTeX |
| Divider | 1px `--border` full-bleed (negative inline margins) |
| Chips | horizontal scroll, chip/13/500 `--surface-2` 1px border r-pill p4/9 g6 |
| Ask field | h32 pill `--surface-2`, placeholder `--text-muted`, trailing 23 circle send (`--primary`, Lucide `arrow-up`) |
| Bottom actions | "Insert into note" (start, `--secondary`, caption600) · "Open in panel →" (end, `--primary`) |
| Tail | 14px square rotated 45°, same material+border, `inline-start` edge (flips RTL), points at anchor |

**States (build all 6):** Default · Thinking (body=2 shimmer bars + 3 tone dots pulsing `sk-think` 1.2s 0.18s stagger; chips/actions hidden) · Expanded thread (follow-ups stack, max-h340 then scroll, Q right-chip / A left) · Pinned/collapsed (pill: avatar + first ~20 chars + Lucide `chevron-down`, draggable) · RTL (tail→inline-end, strip+actions mirror, chips scroll RTL, math LTR island) · Dark (less translucent for legibility, brighten tone accents).
Draggable: whole bubble (re-anchors tail). On-page marks it commands: hand-drawn `--ai-circle` open bezier 3px (drawn-on via perfect-freehand or SVG `stroke-dashoffset`) · `--ai-hi` highlight rect · `--ai-arrow` bezier arrow from tail to region (animated) · `--ai-underline` 2px under a term.

## 3.5 AI side panel · Circle&Ask · Quiz · Guided · Templates
- **AI side panel:** trailing drawer **320** (resizable 300–420) from `inline-end`. Header: "AI Tutor" title + note name caption + Lucide `x` + "Clear". Thread: user msgs end-aligned `--primary` bg/radiant text r18 with **2px end-bottom corner**; AI msgs start-aligned `--surface-2`/`--text` r18 with 2px start-bottom corner; max-w78% p10/14 g8. Timestamps centered caption. Composer: `--surface-2` field + Lucide `mic` + send. Empty: centered `sparkles` + "Ask anything about your notes".
- **Circle & Ask:** lasso/AI-pen region → marching-ants (`--primary` dashed 1px animated) → compact input sheet at anchor ("Ask about this…" + send + 3 chips) → thinking bubble.
- **Quiz mode:** 2–3 flashcard bubbles (same shell, **purple `#A855F7`** tone strip). Top "Question 1 of 3" caption + Lucide `brain`. Body=question. Answer area = embedded mini ruled canvas (write in ink). "Submit" (`--primary`). After: green check / red correction + annotation at answer. Bottom dots progress.
- **Guided mode:** bottom suggestion card slides up (`sheet.present`). Wide h72, 16 from bottom, 24 inline margins, r16 `--surface` e2 orange leading strip. Lucide `sparkles` orange circle + suggestion (1 line ellipsis) + subject pill + "Ask →" (`--primary` pill) + dismiss. "Ask →" expands to canvas bubble (shared-element transition).
- **Templates:** blank · ruled (38px pitch `--border`@intensity, red margin line @x88 `--destructive`@20%) · grid · dotted. Line color from `--paper-rule` (light `#E4DAC4` / dark `#312B22`), intensity slider 0.3–1.0 → opacity.

## 3.6 Reusable components (all states)
| Component | Default | Hover/Press | Selected | Disabled | Loading/Error |
|---|---|---|---|---|---|
| Button primary | h38 r-pill `--primary` bg radiant text p-inline16 | brightness1.06 / scale.98 | — | 40% no-events | spinner / shake + `--destructive` ring |
| Button secondary | `--surface` 1px `--border` `--text` | `--surface-2` | — | 40% | — |
| Icon button | 38 circle transparent `--text-muted` | `--surface-2` + `--text` | `--primary-soft` + `--primary` glyph | 30% | — |
| Pill/tag | chip/13 `--surface-2` 1px border r-pill | border darken | `--primary` bg/radiant | 40% | — |
| Segmented | inset `--surface-2`; thumb `--surface`+e1 | thumb slides (spring) | label600 | 40% | — |
| Text field | h38 r10 `--surface-2` 1px border | — | focus 2px `--primary` ring | 40% no caret | 1px `--destructive` + helper |
| Toggle | 44×26 `--surface-2` 22 knob | — | on=`--primary` track | 40% | — |
| Slider | 4px `--surface-2` + `--primary` fill 18 knob+e1 | knob scale1.1 | — | 40% | — |
| Swatch | 24 circle 1px border | scale1.08 | 2px paper+2px `--primary` ring | — | — |

## 3.7 Settings · Splash · Loading · App icon
- **Settings:** split sub-sidebar (Appearance · AI Tutor · Notes & Sync · Export · About) + content. Grouped cards (`--surface` 1px `--border` r14, rows 1px divided). *Appearance:* mode segmented (Light/Dark/System) · **theme picker** (4 chips, 60px icon preview + 2 accent dots, selected=2px `--primary`+check badge, swaps app icon) · template-line intensity slider · toolbar position segmented. *AI Tutor:* provider select · API key (masked + Lucide `clipboard-paste`) · model · language (Eng/Heb/Auto) · guided sensitivity (Low/Med/High) · response style (Concise/Detailed). *Notes & Sync:* auto-save · iCloud toggle + last-synced · auto-backup. *Export:* default format · include-template toggle. *About:* version · GitHub · privacy.
- **Splash:** `--paper` bg, centered wordmark (34 `--primary` square + `--ai-circle` dot, "Inkling" display/28). No spinner.
- **Loading:** 3 tone-dots (`sk-think`, `--primary`); card thumbnails shimmer.
- **App icon:** squircle (r≈22.5%), top-lit `--primary` gradient, cream ruled page rotated −6°, `--secondary` circle bottom-end with radiant `sparkles`. One per theme, swaps on selection.

---

# 4. Implementation Instructions for Claude Code

Rule of thumb: **structure → shell, behavior → hooks, values → tokens, state → stores.** Components stay dumb/presentational.

## 4.0 File architecture
```
src/
  app/      AppShell.tsx (the grid §1.0; owns --sidebar-w, data-collapsed/-rail)  routes.tsx
  shell/    Sidebar SidebarRow ResizeHandle  LibraryHeader EditorHeader
  screens/
    library/  Library NoteCard FilterTabs EmptyState
    editor/   Editor Canvas Toolbar OptionsStrip PageStrip NotesPane PageIndicator
    settings/ Settings ThemePicker SettingsGroup
  ai/       AIBubble AISidePanel CircleAndAsk QuizCard GuidedCard OnPageMarks
  components/  Button IconButton Pill Segmented TextField Toggle Slider Swatch Popover  (dumb, token-only)
  hooks/    useSidebarResize useSidebarCollapse useHeaderAutoHide useTheme useColorScheme
            useToolbarDock useAIThread useCircleAndAsk usePersistentState useReducedMotion useRTL
  stores/   uiStore editorStore aiStore   (Zustand)
  styles/   tokens.css themes.css base.css
  lib/      freehand.ts katex.ts haptics.ts motion.ts
```

## 4.1 Subagent delegation plan
Deploy in order. **Agents 1 & 2 must fully land + be verified before 3–7 start.** Each has a hard boundary.
| # | Subagent | Owns | Must NOT touch |
|---|---|---|---|
| 1 | **Shell / Layout** | AppShell grid (§1), Sidebar + resize/collapse, both headers + auto-hide, z-index tokens, responsive, editor sub-shell | colors (tokens only), screen content, AI surfaces |
| 2 | **Theme / Tokens** | tokens.css, themes.css (4×light/dark), useTheme, useColorScheme, crossfade, ThemePicker | layout structure, component internals |
| 3 | **Component Library** | all `components/` primitives (§3.6) with every state + states page | screen composition, business logic, hardcoded color |
| 4 | **Library screen** | `screens/library/*`, grid, cards (loading/empty), filter tabs | shell, tokens, primitives' styles |
| 5 | **Editor screen** | `screens/editor/*`, canvas + perfect-freehand, toolbar dock, options strip, page strip, notes pane | AI surfaces, shell, tokens |
| 6 | **AI surfaces** | all `ai/*` — bubble (6 states), panel, circle&ask, quiz, guided, marks, useAIThread | shell, tokens, editor canvas internals (consumes API) |
| 7 | **Settings** | `screens/settings/*`, grouped cards, controls wired to stores | shell, tokens |

Hand-off contract: Shell agent exposes layout slots (`<AppShell sidebar={…} content={…}/>`); Theme agent guarantees every token exists in all 4 themes; Component agent exposes typed props + zero color literals. Downstream agents **compose, never restyle**. New primitive needed → request from agent 3, don't inline.

## 4.2 Custom hooks (extract every behavior — JSX with a pointermove handler is a bug)
```ts
// LAYOUT
useSidebarResize(opts?): { width; isDragging; handleProps }   // writes --sidebar-w via rAF; persists on up; NO state during drag
useSidebarCollapse(): { state:'expanded'|'rail'|'hidden'; toggle(); set() }   // ⌘\, persisted
useHeaderAutoHide(scrollRef, {threshold:6, revealAtTop:12}): { hidden }       // drives --header-shift; forced false under reduced-motion
useToolbarDock(): { edge; pos; isDragging; bind }                            // pointer drag → nearest-edge snap (spring), persists
// THEME
useTheme(): { theme; mode; resolvedMode; setTheme(); setMode() }              // sets html data-theme/mode, persists, crossfades
useColorScheme(): 'light'|'dark'                                             // matchMedia for mode:'system'
// AI / CANVAS
useAIThread(anchorId): { messages; state:'idle'|'thinking'|'streaming'; ask(); insert(); pin(); dismiss() }
useCircleAndAsk(canvasRef): { selecting; region; begin(); submit() }
// UTILITY
usePersistentState<T>(key, initial): [T, set]
useReducedMotion(): boolean
useRTL(): { dir:'ltr'|'rtl'; isRTL }                                          // sets html[dir]
```
Reference — resize hook never re-renders during drag:
```ts
function useSidebarResize() {
  const onPointerDown = (e) => {
    e.currentTarget.setPointerCapture(e.pointerId);
    const shell = document.querySelector('.app-shell');
    const move = (ev) => requestAnimationFrame(() => {
      const w = clamp(ev.clientX - shell.offsetLeft, 220, 360);   // flips for RTL
      shell.style.setProperty('--sidebar-w', w + 'px');           // direct, no setState
    });
    const up = () => { persist(getComputedWidth()); cleanup(); };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up, { once:true });
  };
  return { handleProps:{ onPointerDown, role:'separator' } };
}
```

## 4.3 State — three Zustand stores (narrow selectors only; never subscribe whole store)
```
uiStore     { theme, mode, sidebarWidth, sidebarState, toolbarEdge, language/dir }   // persisted
editorStore { tool, color, strokeWidth, pressureEnabled, pages[], currentPage, selection } // prefs persist; doc→IndexedDB
aiStore      { threadsByAnchor, bubbleState, panelOpen, guidedSuggestion, quizSession }     // transient
```
Live sidebar width during drag = CSS variable only, committed to uiStore on drag end. Drawing strokes in IndexedDB, never React state.

## 4.4 Defensive styling — enforce strictly
**Always:** semantic tokens only (never raw hex) · logical properties (`padding-inline`, `inset-inline-start`, `border-inline-end`) · `min-width:0` on flex/grid children with variable content · sizing from space/radius tokens · z-index from `--z-*` · gate motion on `useReducedMotion()`.
**Never:** `position:fixed/absolute` sidebar with margined content (it's a grid track, period) · hardcoded colors / px z-index / physical left-right props in layout · default component-library chrome (restyle Radix to tokens) · `setState` on pointer-move · `vh` for full-height (use `dvh`) · theming `--paper` or thumbnails · business/scroll/drag logic inside JSX (→ hook).

## 4.5 Motion specs
| Transition | Framer Motion | CSS | Haptic |
|---|---|---|---|
| view.push | tween 0.32s ease[.22,1,.36,1] | 320ms cubic-bezier(.22,1,.36,1) | — |
| sheet.present | spring stiffness380 damping34 | 400ms ease-out + translateY | soft |
| toolbar.dock | spring 520 damping30 mass.8 | — | rigid on snap |
| bubble.appear | spring 600 damping26; scale.92→1 + opacity, origin=tail | 280ms | soft |
| selection | tween 0.12s ease-out | 120ms ease-out | selection |
| page.turn | tween 0.42s ease-in-out | 420ms ease-in-out | light |
| theme.crossfade | opacity 0.22s linear (overlay layer) | 220ms | — |
Micro: tool select→fill scales in + strip swaps · card hover→lift -2px/120ms · chip tap→scale.96 · toggle→knob spring · send→field clears + message springs in. **Reduce Motion:** all springs/scales → 180ms opacity crossfade; bubble scale-in off; toolbar dock instant.

## 4.6 Accessibility & RTL
Hit target ≥44×44 (40 glyph + 4 inset) · focus 3px `--primary`@60% 2px offset on `:focus-visible` · Dynamic Type rem-based (fixed: tool glyphs, page #, dots) · contrast ≥AA (verify dark accent pairs) · every icon button `aria-label`; bubble announces tone; math read as LaTeX.
**RTL:** `html[dir="rtl"]` via useRTL(). Logical props → sidebar moves to trailing (right) edge, selected-row bar + bubble tone strip/tail + side panel flip automatically. Mirror directional glyphs only (chevrons, undo/redo, send, "Open in panel →"). Math & code = LTR islands inside RTL prose. Chips & thumb strips scroll RTL; resize handle clamps from trailing edge.

## 4.7 Build order & acceptance checklist
Order: tokens+themes → shell+sidebar+headers → component library → library screen → editor (canvas, toolbar dock, strips) → AI surfaces (bubble→panel→circle&ask→quiz/guided) → settings → splash/loading/icons + RTL pass + reduced-motion pass.
Done = all true:
- [ ] Sidebar is a grid track, flush at x=0, full dvh, resizable + collapsible
- [ ] Editor header is 44px, auto-hides, costs 0 layout height
- [ ] Zero hardcoded hex / px-z / physical L-R props in components
- [ ] All 4 themes × light/dark render every surface; `--paper` never tints
- [ ] AI bubble matches the 304px redline in all 6 states
- [ ] RTL mirrors with no per-component overrides
- [ ] Reduced-motion path verified
- [ ] No setState during any drag/resize
- [ ] Verified at 1366×1024 first
