# Handoff: Inkling — “Foolscap” iPad app (with selectable themes)

## Overview
**Inkling** is an iPad handwriting + note‑taking app (Apple Pencil / PencilKit) for university students doing serious math, with an AI study **tutor** woven directly onto the page. The chosen visual direction is **Foolscap**: warm, paper‑like, calm, serif‑led. The tutor doesn’t open a panel by default — it writes in the margin (highlight, circle, arrow) and surfaces a compact **AI bubble** anchored to whatever you circled.

This handoff covers the **Foolscap direction only** (the selected one) plus its **6‑theme system**. Two alternate directions (Atelier, Marginalia) appear in the design file for reference but are **out of scope** — do not build them.

## About the design files
The file in this bundle (`StudyInk Directions.dc.html`) is a **design reference created in HTML** — a high‑fidelity prototype of the intended look and behavior. It is **not production code to copy**. Your task is to **recreate these designs natively in SwiftUI for iPadOS (target iOS 26)**, using PencilKit for the canvas and the platform’s real materials/SF Symbols. Where the prototype fakes something (handwriting, frosted glass, hand‑drawn marks), use the native equivalent noted below.

To view the prototype: open `StudyInk Directions.dc.html` in a browser (the bundled `support.js` is its runtime). Scroll to the **“Foolscap”** direction and the **“Foolscap — theme system”** section. Everything else is alternates.

## Fidelity
**High‑fidelity.** Colors, type, spacing, radii, and component anatomy are final. Recreate pixel‑accurately. The design target is **iPad Pro 12.9″ — 1366 × 1024 pt (landscape)**; all measurements below are in pt.

---

## Design tokens (single source of truth)

### Color — Foolscap theme (default). Light / Dark
| Token | Light | Dark | Notes |
|---|---|---|---|
| `pagePaper` | `#FCFAF5` | `#1A1814` | Writing surface. **Never theme‑tinted.** |
| `chromePaper` | `#F6F0E4` | `#232019` | Editor/library content background |
| `sidebar` | `#EFE7D7` | `#1E1B15` | Library + settings sidebar |
| `editorDesk` | `#E7DECB` | `#15130F` | Behind floating panels / segmented tracks |
| `you.accent` | `#2E4057` | `#7FB0E8` | UI tint + your default ink |
| `ai.accent` | `#B5762A` | `#D9A24E` | The tutor’s color |
| `text.primary` | `#2B2722` | `#F2ECE0` | |
| `text.secondary` | `#8A8073` | `#9A9082` | |
| `separator` | `#DED3BE` | `#34302A` | Hairlines, borders |
| `fill.selected` | `#E4D9C2` | `#2C2820` | Selected sidebar row |
| `card.edge` | `#E8DFCD` | `#2A2620` | Note‑card border |
| `ai.highlight` | `#FFD60A @ 38%` | `#FFD60A @ 22%` | Highlighter mark |
| `ai.circle` | `#FF9F0A` | `#FF9F0A` | Hand‑drawn circle stroke |
| `ai.arrow` | `#6B8E4E` → use `#30D158` in dark | `#30D158` | Arrow mark |
| `success` | `#6B8E4E` | `#30D158` | |
| `destructive` | `#FF3B30` | `#FF453A` | |

Contrast: `text.primary` on `pagePaper` ≈ AAA; `you.accent`/`ai.accent` on `chromePaper` ≥ 4.5:1 (AA). Verify the dark pairs meet AA before shipping.

### AI bubble tone accents (left strip color = answer type)
`teaching #2E4057` · `correct #6B8E4E` · `correction #C2683D` · `error #B23A2E` (light). In dark, brighten to `#7FB0E8 / #30D158 / #E08A5E / #FF6A5A`.

### Typography
| Role | Family | Size / Weight | Line‑height | Scales w/ Dynamic Type? |
|---|---|---|---|---|
| Display / Title Large | **Fraunces** (Semibold) | 28 / 600 | 1.05 | Yes (`.largeTitle`) |
| Title | Fraunces (Semibold) | 20 / 600 | 1.1 | Yes (`.title2`) |
| Body / AI response | **SF Pro** (Regular) | 16 / 400 | 1.5 | Yes (`.body`) |
| Callout / toolbar label | SF Pro | 15 / 400 | 1.3 | Yes (`.callout`) |
| Caption / metadata | SF Pro | 12 / 400 | 1.3 | Yes (`.caption`) |
| Chip | SF Pro (Medium) | 13 / 500 | 1.2 | Yes |
| Handwriting (user ink) | rendered PencilKit strokes | — | — | n/a |
| Math | **KaTeX / SwiftMath** | — | — | n/a |
| Mono (token/code chips) | SF Mono | 12–13 / 500 | — | Yes |

> The prototype uses the Google font **Caveat** to *fake* handwriting and an italic serif to *fake* math — in the app, handwriting is real PencilKit ink and math is KaTeX/SwiftMath.

### Spacing — 8‑pt grid
`4, 8, 12, 16, 20, 24, 32, 48`

### Corner radius
`sm 8 · md 12 · lg 16 · xl 20 · pill 999`

### Stroke width (ink + UI)
`hairline 1 · thin 1.5 · regular 2 · thick 3`

### Elevation (color `#28221C` warm‑black)
| Token | y / blur / spread | Opacity |
|---|---|---|
| `e1` | 0 / 2 / 0 | 6% (cards) |
| `e2` | 0 / 24 / −6 | 14% (toolbar, popovers) |
| `e3` | 0 / 44 / −10 | 22% (AI bubble, sheets) |

### Motion (named transitions)
| Token | Duration | Curve / spring | Extra |
|---|---|---|---|
| `view.push` | 0.35s | `spring(response 0.45, damping 0.82)` | |
| `sheet.present` | 0.40s | `spring(0.50, 0.85)` | |
| `toolbar.dock` | 0.30s | `spring(0.38, 0.80)` | snaps to nearest edge |
| `bubble.appear` | 0.28s | `spring(0.32, 0.78)` | scale 0.92→1 + opacity, origin = tail anchor |
| `selection` | 0.12s | `easeOut` | |
| `page.turn` | 0.45s | `easeInOut` | |

**Haptics:** tool select → `.selection`; bubble appear → `.impact(.soft)`; insert‑into‑note / correct answer → `.notification(.success)`; error → `.notification(.error)`.
**Reduce Motion:** replace all springs/scale with a 0.2s crossfade; disable the bubble scale‑in.

---

## Screens / Views

### 1. Library (home)
**Purpose:** browse and open notes, organized by subject.
**Layout:** `NavigationSplitView`. Sidebar **260pt** fixed, `sidebar` bg, 1pt `separator` trailing border, padding 22/16/16. Content area `chromePaper`.

**Sidebar (top→bottom):**
- Wordmark row: 26pt rounded‑10 square in `you.accent` with a 13pt `ai.highlight` dot inside → “Inkling” in **Fraunces 20/600**. Padding 0 6; 18pt below.
- Search field: height 38, radius 10, bg `#F8F3E9`, 1pt `separator`, `magnifyingglass` + “Search notes” (`text.secondary`), trailing `⌘K` mono chip.
- **Smart section** rows (height 40, radius 9, 11pt gap): `All notes` (selected) · `Recents` · `Favorites`. Each = SF Symbol (19pt) + label (15/Body) + right‑aligned count (`text.secondary`, tabular).
- 1pt divider.
- “SUBJECTS” caption (11.5/700, .1em, uppercase, `text.secondary`).
- Subject rows: 11×11 rounded‑3 color **dot** + label + count. Colors per subject (Calc `#FF9F0A`, Linear Alg `you.accent`, Organic `#30D158`, History `#BF5AF2`).
- 1pt divider · `Recently Deleted` · flex spacer · `Settings` (pinned bottom).

**Row states:** default (transparent) · **selected** (`fill.selected` bg + 3pt `you.accent` bar inset at the leading edge, label 600) · **pressed** (`#E9DFCB`).

**Content area:**
- Top bar (padding 26/34/0): `H1 “All notes”` Fraunces 30/600. Right cluster (10pt gap): **Ask AI** pill (height 38, radius pill, `you.accent` bg, `sparkles` + label white) · circular 38 icon buttons for `Import (doc)` and `More (ellipsis)` (`pagePaper` bg, 1pt separator) · **New note** 38 circle `you.accent` `plus`.
- Filter pills (18/34/0): segmented as pills — active = `text.primary` bg / white text; rest = `#EDE6D7` bg, 1pt soft border. Right: “Sorted by date modified” caption.
- **Note grid:** `LazyVGrid`, **3 columns**, 20pt gap, padding 22/34/34. Card = radius 14, `pagePaper` bg, 1pt `card.edge`, `e1` shadow:
  - Cover (height 196): a faux page — light handwriting hint (Caveat in proto → a thumbnail render in app) + 6 ruled lines.
  - Footer: name (15/600, ellipsis) + 9px subject dot; date (12, `text.secondary`).
- **Loading card:** cover = shimmer gradient (`separator`→`chromePaper`), 1.4s linear; two skeleton bars in footer.
- **Empty state** (when a folder has 0 notes): centered, `sparkles`‑in‑circle + “No notes yet. Tap + to start.” in `text.secondary`.

### 2. Note editor (the hero) — light & dark
**Purpose:** write math by hand; get on‑page AI help.
**Layout:** full‑bleed `PKCanvasView`. Fixed top **header 58pt**; floating toolbar; right **page strip 76pt**.

- **Header (58pt, `chromePaper`, 1pt bottom separator):** leading back‑chevron (34 rounded square, `editorDesk` bg) + title block (note name Fraunces 18/600, “Calculus I · Edited just now” caption). Trailing: `share` + `pages` (36 rounded‑10) + **Tutor** pill (`ai.accent` bg, `sparkles`).
- **Canvas:** `pagePaper`, college‑ruled lines = `repeating-linear-gradient` 38pt pitch in a faint rule color (`#E4DAC4` light / `#312B22` dark) starting 24pt down; a 1pt red margin line at x≈88 (`destructive @ ~20%`). **Ink adapts:** dark‑mode handwriting renders light on charcoal — paper itself stays its own dark surface, never theme‑tinted.
- **Floating toolbar** (centered, 74pt from top): pill, radius pill, `chromePaper @ ~96%` + `e2`, 1pt separator. Order: **grip** · undo · redo │ pen(active) · fountain · monoline · highlighter · pencil · eraser · lasso · hand │ ruler · text · AI‑pen · AI‑history │ more. 40×40 hit per tool; **active tool** = filled `you.accent` circle, white glyph. Toolbar is **draggable and docks to any edge** (`toolbar.dock` spring).
- **Inline options strip** (attached under toolbar, 128pt from top): radius 16, same material. Contents: 8 color swatches (24, selected ring = 2pt paper + 2pt `you.accent`) · divider · 4 stroke‑size dots (4/7/10/14) · divider · **Pressure** toggle. (Per‑tool variants: highlighter adds blend toggle; eraser shows object‑vs‑pixel + size; lasso shows mode.)
- **Page strip (right, 76pt, `chromePaper`):** vertical 48×62 page thumbs (ruled mini), current = 2pt `you.accent` border, number caption below; dashed “+ add page” at bottom. Tap to jump; long‑press → reorder/duplicate/delete.
- **Page indicator:** bottom‑center pill “3 / 7”, `thinMaterial`.

**On‑page AI marks (see §3):** orange hand‑drawn circle, yellow highlight, green arrow, anchored AI bubble with tail.

### 3. AI bubble (component — the heart) — all states
Compact card, **not** a panel. Anchored beside whatever the student circled, with a speech tail pointing at it.
- **Size:** **304pt** wide (≈300–320), height hugs content (max ~4 body lines before “show more”).
- **Material:** `.ultraThinMaterial` (light) / `.regularMaterial` (dark) over the live canvas — frosted, warm. Radius **18**, 1pt hairline border, `e3`.
- **Left tone strip:** **4pt**, full height, colored by answer type (teaching/correct/correction/error — see tokens).
- **Top row:** 22pt circular avatar in `ai.accent` with white `sparkles`; “Inkling Tutor” (Caption, `text.secondary`); trailing dismiss ✕ (18pt).
- **Body:** Body 16/`text.primary`. Referenced term gets a `ai.highlight` background pill; math renders inline (KaTeX/SwiftMath). Example copy: *“Exactly right — you used the **chain rule**: the outer derivative cos(x²) times the inner 2x gives the result.”*
- **Divider** (1pt, full‑bleed).
- **Chips row:** horizontally scrollable pills — 13/500, `chromePaper` fill, 1pt separator, radius pill, padding 6×11. Example: `Why 2x?` · `Quiz me` · `Show steps`.
- **Ask‑more field:** height 34 pill, `chromePaper`, placeholder “Ask a follow‑up…”, trailing 24pt circular send (`you.accent`, arrow).
- **Bottom actions:** “Insert into note” (left, `ai.accent`, Caption 600) · “Open in panel →” (right, `you.accent`).
- **Tail:** small triangle, same material/border, points at the anchor region.

**States:** Default · **Thinking** (body = 2 shimmer bars + 3 tone‑colored pulsing dots) · **Expanded thread** (scrollable, follow‑up Q&A stacked) · **Pinned/collapsed** (small pill: avatar + first ~20 chars + chevron) · RTL · Dark. Appear via `bubble.appear`.

**Canvas annotation marks (drawn on the page, not in the bubble):**
- **Circle:** open bezier, `ai.circle #FF9F0A`, 3pt, ~hand‑drawn (slightly non‑closed). In app: animate a `PKStroke` or `Canvas` path draw‑on.
- **Highlight:** rounded rect behind text, `ai.highlight` (38%/22%).
- **Arrow:** bezier from bubble tail to region, `ai.arrow`, 3pt, with a 2‑line arrowhead; animated draw‑on.
- **Underline:** 2pt `ai.circle` or `you.accent` under a term.

### 4. Settings → Appearance (+ theme system)
`NavigationSplitView`. Sidebar lists Appearance (selected) · AI Tutor · Notes & Sync · Export · About. Content = `chromePaper`, H1 “Appearance” Fraunces 30.
Grouped iOS‑style cards (`pagePaper` bg, 1pt `card.edge`, radius 14, rows divided by 1pt):
- **MODE:** “Appearance” row → segmented **Light / Dark / System** (`editorDesk` track, selected = `pagePaper` + `e1`).
- **THEME:** caption “pairs your ink with your tutor’s color”; card holds a wrapping row of **theme chips** (see §Theme system).
- **CANVAS:** “Template line intensity” → slider (`you.accent` fill, 18pt knob, `e1`); “Toolbar position” → segmented Top/Bottom/Left/Right.

Also specify (per brief, same grouped style): **AI Tutor** (API key masked + paste, default language English/Hebrew/Auto, Guided‑Mode sensitivity Low/Med/High, response style Concise/Detailed), **Notes & Sync** (auto‑save, iCloud toggle + last‑synced, auto‑backup), **Export** (default PDF/PNG, include template background), **About** (version, GitHub, privacy).

### 5. Splash / launch & loading indicator
- **Launch:** `pagePaper` bg, centered wordmark — the 34pt `you.accent` rounded square + `ai.highlight` dot, “Inkling” Fraunces 28 below, all centered. No spinner.
- **In‑app loading:** the 3 tone‑colored dots used in the bubble’s Thinking state (`sk-think`, 1.2s, 0.18s stagger), tinted `you.accent`.

---

## Theme system (6 selectable themes)
Each theme = **same token names, different values**. A theme supplies `you`/`ai` accents (light + dark) and the chrome tints (`chrome`/`sidebar`/`editorDesk`). **`pagePaper` and note thumbnails never change** — only the chrome tints. Selecting a theme also swaps the **alternate app icon**.

| Theme | you (L) | ai (L) | you (D) | ai (D) | chrome | sidebar | editorDesk |
|---|---|---|---|---|---|---|---|
| **Foolscap** | `#2E4057` | `#B5762A` | `#7FB0E8` | `#D9A24E` | `#F6F0E4` | `#EFE7D7` | `#E7DECB` |
| **Botanica** | `#2F6048` | `#C2683D` | `#7CC79E` | `#E08A5E` | `#F1F4ED` | `#E7EEE2` | `#DCE6D6` |
| **Plum** | `#5B3A6B` | `#B08328` | `#C79BD6` | `#D9A94E` | `#F4EFF3` | `#ECE3EC` | `#E4D6E2` |
| **Marine** | `#1F5E63` | `#C45B45` | `#6FC2C7` | `#E0846B` | `#ECF3F2` | `#E2EDEC` | `#D5E6E4` |
| **Ember** | `#8A3B33` | `#B5762A` | `#E08077` | `#D9A24E` | `#F7EFEA` | `#F1E4DD` | `#ECD9CF` |
| **Slate** | `#3C4149` | `#9A7B45` | `#9AA0AA` | `#C5A36A` | `#F1F1F2` | `#E8E8EA` | `#DEDEE1` |

Dark chrome stays the Foolscap dark set (`chrome #232019`, `sidebar #1E1B15`, `editorDesk #15130F`) for all themes — only the accents shift in dark.

**App icon (per theme):** rounded‑squircle (radius ≈ 22.5% of size) filled with a top‑lit gradient of `you.accent`; a cream (`#FCFAF5`) ruled “page” rotated −6°; an `ai.accent` circle (≈30% size) bottom‑right with a white `sparkles`. Provide 6 pre‑rendered `AppIcon` assets and switch with `UIApplication.shared.setAlternateIconName("Theme_<name>")` keyed to the selected theme.

**Theme chip (picker):** ~104pt cell — 60pt app‑icon preview + name (13.5/600) + two 13pt dots (you, ai). Selected = `pagePaper` bg, 2pt `you.accent` border, check badge top‑right.

**Suggested model:**
```swift
enum Theme: String, CaseIterable { case foolscap, botanica, plum, marine, ember, slate }

struct Palette {            // resolve by (theme, colorScheme)
    let pagePaper, chromePaper, sidebar, editorDesk: Color
    let you, ai, textPrimary, textSecondary, separator: Color
    let aiHighlight, aiCircle, aiArrow, success, destructive: Color
}
// One accessor: Palette.for(theme, scheme) → Palette. Inject via @Environment.
```

---

## Iconography — SF Symbols (use exclusively)
| Action | Symbol | Action | Symbol |
|---|---|---|---|
| Pen | `pencil.tip` | AI pen | `wand.and.stars` |
| Fountain | `pencil.and.outline` | AI history | `clock.arrow.circlepath` |
| Highlighter | `highlighter` | Undo / Redo | `arrow.uturn.backward` / `.forward` |
| Eraser | `eraser` | New note | `square.and.pencil` |
| Lasso | `lasso` | Search | `magnifyingglass` |
| Hand | `hand.draw` | Ask AI / tutor | `sparkles` |
| Ruler | `ruler` | Send | `arrow.up.circle.fill` |
| Text box | `textformat` | Share | `square.and.arrow.up` |
| More | `ellipsis` | Pages | `doc.on.doc` |
| Settings | `gearshape` | Favorite / Recents | `star` / `clock` |
| Folder / Delete | `folder` / `trash` | | |

---

## Interactions & behavior
- **Open note:** tap card → `view.push` into editor.
- **Circle & Ask:** lasso/AI‑pen a region → AI bubble animates in at the anchor (`bubble.appear`); the orange circle draws on; arrow draws from tail to region.
- **Tool select:** tap → fill animates (`selection`) + `.selection` haptic; options strip swaps to that tool’s controls.
- **Toolbar drag:** lift → follows finger → releases → docks to nearest edge (`toolbar.dock`).
- **Bubble actions:** `Insert into note` writes the answer as ink/text onto the page; `Open in panel →` expands the thread into the right‑side AI panel (320pt drawer); chips send a canned follow‑up; pin → collapses to the small pill.
- **Guided mode:** a bottom suggestion card slides up (`sheet.present`) when the tutor detects something; “Ask →” expands it into a canvas bubble.
- **Loading:** bubble Thinking state while awaiting model; cards show shimmer while thumbnails render.

## State management
- `selectedTheme: Theme`, `colorScheme` (Light/Dark/System) — persisted (AppStorage); drives `Palette`.
- `currentTool`, `currentColor`, `strokeWidth`, `pressureEnabled`, `toolbarEdge`.
- `note` (pages, strokes via PencilKit `PKDrawing`), `currentPage`.
- `aiThreads: [Anchor: [Message]]`, `bubbleState` (default/thinking/expanded/pinned), `panelOpen`.
- AI calls: stream tokens → Thinking → render; math post‑processed to KaTeX.

## Accessibility & RTL
- **Hit target** 44×44pt min (40pt glyphs carry a 4pt touch inset).
- **Focus/selection:** 3pt ring, `you.accent` @ 60%, 2pt offset.
- **Dynamic Type:** Body/Title/Caption scale; **fixed:** tool glyphs, page numbers, swatch/size dots.
- **Reduce Motion:** springs → 0.2s crossfade; no bubble scale‑in.
- **VoiceOver:** bubble announces its tone (“correction”) and reads math as spoken LaTeX.
- **RTL (Hebrew):** `.environment(\.layoutDirection, .rightToLeft)`. Sidebar → trailing edge; selected‑row bar, bubble tone strip, and tail flip sides; chips scroll RTL; directional glyphs mirror (undo/redo/send/chevrons); **math & code stay LTR islands** inside RTL prose. Use leading/trailing — never left/right.

## Engineering notes (SwiftUI on iOS 26)
| Element | Implementation | Flag |
|---|---|---|
| Library shell / Settings | `NavigationSplitView` | native |
| Note grid | `LazyVGrid(.adaptive)` | native |
| **Handwriting canvas** | `PKCanvasView` via `UIViewRepresentable` | ⚑ PencilKit/UIKit |
| Floating toolbar | overlay + `.glassEffect` (iOS 26) or `.background(.regularMaterial)`; draggable, edge‑snap | native |
| **AI bubble** | anchored overlay, `.ultraThinMaterial`/`.regularMaterial`, `matchedGeometryEffect` for expand→panel | native |
| Inline math | SwiftMath or render KaTeX → image | lib |
| **Long‑form math (AI panel)** | `WKWebView` + KaTeX | ⚑ UIKit |
| On‑page marks (circle/arrow/highlight) | `Canvas`/`Shape` overlays or injected `PKStroke`s, animated draw‑on | native |
| Side AI panel | `.inspector` or custom 320pt drawer | native |
| Theme | `enum Theme` → `Palette` struct; reactive to `@Environment(\.colorScheme)` | native |
| App‑icon swap | `setAlternateIconName` per theme | native |

**Tradeoffs / watch‑outs:** keep ≤2 stacked blur layers over the live canvas (perf); the “hand‑drawn” circle is an aesthetic choice — drive it with a `Canvas` timeline or a pre‑built `PKStroke`, not a perfect ellipse; KaTeX in `WKWebView` is the pragmatic path for complex display math.

## Files
- `StudyInk Directions.dc.html` — the full design reference (open in a browser; needs `support.js` beside it). Build from the **“Foolscap”** direction + **“Foolscap — theme system”** + **“System & engineering handoff”** sections. Ignore Atelier and Marginalia.
- `support.js` — runtime for the prototype (not part of the app).
