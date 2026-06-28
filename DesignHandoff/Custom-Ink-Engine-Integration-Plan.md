# Custom Ink Engine — Integration Plan

Wiring the prototype vector ink renderer (`StudyInk/Canvas/CustomInkLab.swift` →
`VectorInkView`) into the real editor, replacing the PencilKit-based multi-page
engine (`StudyInk/Canvas/NoteCanvasEngine.swift` → `DocumentScrollView`).

**Status:** planning only. No code changed by this document.

---

## 0. Executive summary

The real editor is a SwiftUI view (`NoteEditorView`) that talks to a UIKit engine
(`DocumentScrollView`) *exclusively through* one bridge object (`CanvasController`).
The editor itself almost never touches PencilKit directly — the two exceptions are:

1. **AI ink insertion** (`AIModes.writeInk` / `answerInInk` / `drawSketch`) takes a
   `PKCanvasView?` and mutates `canvas.drawing` directly. (`StudyInk/AI/AIModes.swift`)
2. Per-stroke heuristics in `onStroke` read `canvasController.canvasView?.drawing.strokes`
   for `renderBounds` (`NoteEditorView.swift` ~line 869).

Everything else (lasso, shape edit, undo/redo, zoom, paging, persistence, AI
context, OCR, export, thumbnails, dark mode) flows through `CanvasController` and/or
the *persisted* `PKDrawing` blob — **not** the live canvas. That is the single most
important fact for this migration: **if the custom engine keeps `CanvasController`'s
public surface intact and keeps writing a `PKDrawing`-compatible blob to
`Page.drawingData`, the blast radius is contained to the canvas layer.**

The custom engine is currently a *single-page* `UIScrollView` + `VectorInkView`
proof of perf (committed bitmap + wet/pending `CAShapeLayer`s). It has none of the
multi-page document, persistence, lasso, shape, AI, or dark-mode machinery yet.
This plan closes that gap behind a feature flag, capability by capability.

**Biggest risks** (detailed in §7): the custom stroke model is *lossy vs PKStroke*
(no per-point pressure/azimuth/altitude, no ink-type, fixed color) so a naive
swap degrades fidelity and breaks round-tripping; the entire AI-ink subsystem is
hard-bound to `PKCanvasView` + `PKStroke`; lasso/shape/clipboard all assume
`PKDrawing` math; and the persisted blob is `PKDrawing.dataRepresentation()` which
also feeds OCR, export, thumbnails, and the AI vision context — so the data model
must coexist with PencilKit, not replace it, for a long time.

**Recommended first step** (see §6, Phase 1): render *committed* ink with the
custom `VectorInkView` while **keeping PKCanvasView as the live input + source of
truth** — i.e. the custom view only replaces the *inactive-page cached image* and,
later, the committed-strokes display, reading the same `PKDrawing`. This proves the
vector renderer against real notes (sharp zoom, perf) with zero data-model or
input-handling risk, and is fully reversible by a flag.

---

## 1. The API surface the editor/controller expects

The editor binds to `CanvasController` (a `@StateObject` in `NoteEditorView`,
line 12). The controller in turn holds `weak var canvasView: PKCanvasView?` and
`weak var engine: DocumentScrollView?`. To swap the engine you must satisfy
**(A)** everything `CanvasController` exposes to SwiftUI, **(B)** everything the
editor calls on `engine` directly via `canvasController.engine?…`, and **(C)** the
direct `canvasView` touches.

### 1A. `CanvasController` published state & callbacks (consumed by SwiftUI)

Geometry (read by overlays every frame — see `transform(forPage:)` /
`canvasTransform(forPage:)`):

| Member | Type | Role |
|---|---|---|
| `zoomScale` | `@Published CGFloat` | current document zoom |
| `pageScreenOrigins` | `@Published [CGPoint]` | screen origin of each page; overlays anchor here |
| `currentPageIndex` | `@Published Int` | settled page (live canvas mounts here) |
| `visiblePageIndex` | `@Published Int` | live page-under-center (navigator) |
| `lassoPoints` | `@Published [CGPoint]` | live lasso loop (canvas coords) |
| `lassoRectangular` | `@Published Bool` | marquee vs freeform |
| `isContentReady` / `markReady()` | `@Published Bool` | drives the editor loader |
| `inkScale` | `var CGFloat` | supersample factor; **leaks into editor math** (overlay transforms, snap metrics, AI scaling) |

Callbacks the engine fires (editor sets these in `.onAppear`, ~lines 851–998 +
`wireCanvasSave` ~2030):

| Callback | Signature | Fired when |
|---|---|---|
| `onDrawingChanged` | `(Int, PKDrawing) -> Void` | debounced save; editor writes `page.drawing` |
| `onStroke` | `(Int, PKStroke) -> Void` | each committed stroke; arms tutor, audio sync, glyph prune |
| `onPencilHold` | `() -> Void` | ~1s pencil hold → Circle & Ask |
| `onInterceptedTap` | `() -> Void` | dismiss-tap intercept (close drawer) |
| `onShapeCreated` | `(Int,Int,Shape,PKInk,Double,String)` | auto-shape snapped |
| `onShapeTapped` | `(Int,Int,Shape,PKInk,Double,String)` | finger-tap a shape → node edit |
| `onCanvasFingerTap` | `(CGPoint)` | empty-canvas tap (page coords) → media select / paste / concept |
| `onLassoBegan` / `onLassoComplete` | `()` / `([CGPoint])` | lasso lifecycle (canvas coords) |
| `onAddPage` | `() -> Void` | trailing add-page affordance |

Providers the engine pulls (editor sets, ~lines 880–894):

| Provider | Signature | Returns |
|---|---|---|
| `drawingProvider` | `(Int) -> PKDrawing` | a page's canonical ink |
| `snapshotProvider` | `(Int) -> PageRenderer.Snapshot?` | page render data |

Tool/undo state the controller owns and applies to the canvas:
`toolState`, `isRulerActive`, `pencilOnly`, `autoShapes`, `snapToGrid`,
`canUndo`/`canRedo`, `isDarkMode`, `lastEraserKind`; methods `select(_:)`,
`undo()`/`redo()`/`refreshUndoState()`, `toggleEraser()`, `applyTool()`,
`attach(_:)`, `inkColor(for:)`, `transform(forPage:)`, `canvasTransform(forPage:)`,
`scrollToPage(_:)`, `autoScroll(by:)`, `commitPendingInk()`, `setTapIntercept(_:)`,
`noteDrawingGestureBegan()` + `drawingGestureBeganToken`, `strokeClipboard` /
`hasPasteContent`.

### 1B. Methods the editor calls on `engine` directly

(`canvasController.engine?…` — these are the `DocumentScrollView` API the custom
engine must reimplement)

- Paging / save: `scrollToPage(_:animated:)`, `autoScroll(by:)`, `commitPendingInk()`,
  `apply(pageSizes:signature:)`, `ensureContent()`, `refreshPage(_:)`, `appearanceChanged()`.
- Shape edit: `beginStrokeEdit(at:)`, `endStrokeEdit(with: PKStroke)`.
- Lasso selection lifecycle: `liftStrokeSelection([Int])`, `commitStrokeSelection(rotation:scale:translation:selection:)`,
  `cancelStrokeSelection()`, `deleteStrokeSelection()`, `duplicateStrokeSelection(…)`,
  `copyStrokeSelection(…)`, `cutStrokeSelection(_:)`.
- Clipboard / space: `pasteStrokes(at:)`, `insertSpace(belowPageY:amount:)`.
- Lasso gesture arm: `setLassoGestureActive(_:)`, `setTapIntercept(enabled:)`.

Note every one of these speaks **`PKStroke` / `PKDrawing` / `StrokeSelection`** and
**canvas (inkScale×) coordinates**.

### 1C. Direct `canvasView` (PKCanvasView) touches

- `AIModes.writeInk/answerInInk/drawSketch(on: canvasController.canvasView)` —
  appends `[PKStroke]` to `canvas.drawing`, with its own undo registration and a
  `1/canvas.transform.a` scale to compensate for `inkScale` (`AIModes.swift` ~292).
- `onStroke` reads `canvasController.canvasView?.drawing.strokes.map(\.renderBounds)`
  for glyph pruning (~869).
- The SwiftUI wrapper `NoteCanvasView` (bottom of `NoteCanvasEngine.swift`) sets
  `controller.isDarkMode` and calls `engine.apply/ensureContent`.

---

## 2. Gap analysis — what the custom engine must add

`VectorInkView` today: stores `strokes: [[InkSample]]` (location + width only),
draws a committed bitmap off-main + `CAShapeLayer` wet/pending layers, super-samples
2×, supports pen + whole-stroke eraser + zoom re-raster. `CustomInkScroll` is a
single `UIScrollView` with one ink view; `InkLabController` is a toy bridge.

| Capability | PencilKit engine has it | Custom engine status | Gap to close |
|---|---|---|---|
| Vector stroke model | `PKStroke` (per-point pressure/azimuth/altitude/force, ink type, color, transform, mask) | `InkSample{location,width}`, single hardcoded color | **Large.** Need a richer `VectorStroke` (color, tool kind, opacity, per-point width/pressure) **or** keep `PKStroke` as the model and only borrow the renderer. |
| Persistence blob | `PKDrawing.dataRepresentation()` ↔ `Page.drawingData` | none | Need an encoder/decoder; must coexist with the PK blob (§3). |
| Multi-page document | full `DocumentScrollView` (stitched pages, one live canvas, cached renders, centering, settle/mount) | one page, one view | **Large** (§4). |
| Page backgrounds (paper/grid/PDF) | `PageContainerView.draw` + `PageRenderer.drawBackground` | white fill only | Reuse `PageRenderer.drawBackground`; the ink view draws *only ink* over a background layer. |
| Per-tool (color/width/highlighter/pencil/ruler) | `ToolState.pkTool` applied to canvas | one pen, one eraser | Map `ToolState` → vector render params; ruler; highlighter (multiply blend); pixel vs object eraser. |
| Pressure / tilt | full from `UITouch` + PencilKit | `force` only (already sampled) | Capture azimuth/altitude if fidelity wanted; otherwise accept width-from-force. |
| Undo/redo | `PKCanvasView.undoManager` | none | Own `UndoManager`; wire `canUndo/canRedo` + multi-finger tap undo/redo. |
| Lasso select/move/rotate/scale | `StrokeSelector.applyTransform` on `PKDrawing` | none | Reimplement selection geometry on the vector model (or keep PK strokes; §5). |
| Auto-shapes | `ShapeRecognizer` on `PKStroke` + hold-snap recognizer | none | `ShapeRecognizer` takes `PKStroke`/points; adapt to vector stroke or convert. |
| AI ink insertion | append `[PKStroke]` to `canvas.drawing` | none | **Hard** — `InkWriter` emits `PKStroke`. Need a `[PKStroke] → [VectorStroke]` bridge or keep PK as the live model (§5). |
| Dark-mode ink adaptation | `InkColorAdapter` storage↔display + pinned-light canvas | none | Adapt at load/save like the engine does; custom renderer draws literal colors. |
| Zoom / raster budget | `updateRasterScale` (budgeted, active-page only) | `setRasterScale` + budget (already prototyped) | Already close; needs the multi-page + background variants. |
| OCR / AI vision / export / thumbnails | all read `Page.drawingData` via `PageRenderer` | n/a (they read the blob, not the canvas) | **Works unchanged IF the blob stays PK-compatible** (§3, §5.6). |
| Circle & Ask region capture | renders `PageRenderer.Snapshot` (persisted blob), crops | n/a | Unchanged if blob stays compatible. |
| Geometry publishing for overlays | `publishGeometry` → `pageScreenOrigins`, `zoomScale` | none | Reimplement; overlays depend on this 1:1. |
| `inkScale` coordinate contract | canvas renders at inkScale×; editor math divides by it | renders at native page coords | **Decision point** — custom engine can render sharp at zoom *without* inkScale (it re-rasters), so `inkScale` could become 1. But the editor multiplies snap metrics, AI strokes, lasso, paste, insert-space by `inkScale`. Keep `inkScale = 1` and audit every site, OR keep the supersample contract. |

---

## 3. Data model & persistence

### 3.1 How ink is persisted today

- Core Data, **programmatic model** (`PersistenceController.model`), entity `Page`,
  attribute `drawingData: Binary (allowsExternalBinaryDataStorage = true)`.
- `Page.drawing` getter/setter (`Models.swift` 126–135) wraps
  `try? PKDrawing(data:)` / `newValue.dataRepresentation()`. **The blob is opaque
  PencilKit format.**
- Save path: engine `persist()` → `controller.onDrawingChanged(index, canonicalDrawing)`
  → editor writes `pages[index].drawing = drawing` → `PersistenceController.shared.save()`
  (debounced 0.4s in the engine; `wireCanvasSave`).
- **CloudKit:** the container is `NSPersistentCloudKitContainer` when
  `settings.iCloudSync` is on (`PersistenceController.swift` 18–27), with persistent
  history tracking. **Any schema change must be CloudKit-compatible** (additive,
  optional attributes only — no renames/removals, no required fields).
- Same blob feeds: `PageRenderer.Snapshot.drawingData` → export PDF/PNG, thumbnails,
  OCR (`OCRService.indexPage`), AI vision context (`NoteContextBuilder` →
  `PageRenderer.render`), Circle & Ask crop, library search index, clipboard
  cross-app image. **Many readers, all via `PKDrawing`.**

### 3.2 Plan: additive coexistence, zero data loss

The custom engine's strokes are *not* representable as `PKDrawing` losslessly (and
vice-versa), so do **not** overwrite `drawingData`. Instead:

1. **Add an optional attribute** `vectorInkData: Binary (external, optional)` to the
   `Page` entity (and a `vectorInkVersion: Int16` for forward-compat). Additive +
   optional ⇒ CloudKit-safe, no migration of existing rows, old builds ignore it.
   Mirror the `drawing` accessor with a `vectorStrokes` computed property
   (Codable `[VectorStroke]` → JSON or a compact binary).
2. **Keep `drawingData` as the canonical/interop blob.** Whenever vector ink is
   saved, *also* write a `PKDrawing` projection into `drawingData` (best-effort:
   each `VectorStroke` → a `PKStroke` with `.pen` ink, the stroke's color, and
   per-point `PKStrokePoint`s carrying width as `size`). This keeps OCR, export,
   thumbnails, AI vision, and *old app versions / other devices via CloudKit* all
   working off `drawingData` with no code changes. The vector blob is the
   high-fidelity master; the PK blob is the lossy-but-universal projection.
3. **Migration direction is one-way and lazy.** On first open of a page under the
   custom engine: if `vectorInkData == nil` but `drawingData != nil`, *import*
   `PKDrawing → [VectorStroke]` (centerline + width from `PKStrokePoint.size`,
   color from ink) into memory, but **do not** clear `drawingData`. Persist
   `vectorInkData` only on the next edit. Existing notes are never rewritten until
   touched ⇒ zero-risk, fully reversible (flip the flag, the PK blob is still there).
4. **`VectorStroke` shape** (proposed Codable):
   `{ points: [{x,y,width}], colorHex, opacity, toolKind, isHighlighter }`.
   Start minimal (matches `InkSample` + color + tool), extend later.

### 3.3 Round-trip fidelity contract

- PK→vector import: sample `stroke.path` (it already does this in `averageWidth` /
  `strokeDistance`), keep `path[i].location.applying(transform)` and `size.width`.
- vector→PK export: build `PKStrokePath(controlPoints:)` exactly like
  `PageRenderer.boldened` already does (proves the pattern works off-main).
- Color/dark-mode: store **canonical (light)** colors in `vectorInkData`, mirror the
  `InkColorAdapter` storage↔display dance the engine does at the load/save boundary.

---

## 4. Multi-page architecture

The current engine is **one scroll view, all pages stitched vertically, ONE live
PKCanvasView** that mounts on the settled page; inactive pages show cached
`PageRenderer` bitmaps. This "one live surface, N cached images" design exists for
memory (PencilKit's live tiling is expensive) and is the reason for the whole
mount/settle/bridge/reveal dance (`mountCanvas`, `settleActivePage`,
`bridgeActiveReveal`, `activatePage`).

**The custom engine does not have PencilKit's memory cost** — a `VectorInkView`
committed page is one budgeted bitmap; the wet/pending layers exist only while
drawing. Two viable designs:

### Option A — One shared `VectorInkView`, mirror the current design (recommended)

Keep `DocumentScrollView`'s exact structure: page containers with cached background
+ committed-ink images; one *live* `VectorInkView` reparented onto the settled page.
- Pro: minimal change to the proven scroll/centering/settle/geometry machinery;
  overlays, `pageScreenOrigins`, paging all keep working unchanged.
- Pro: the per-page cached image is just `PageRenderer.drawBackground` + the page's
  committed vector ink (rendered by the same static `drawStroke`).
- Con: still has the mount/swap bridge, but it gets *simpler* (vector commit is
  cheap and synchronous-ish; less async-PencilKit flashing to hide).

### Option B — One `VectorInkView` per page, all live

Because vector pages are cheap, every page could host its own ink view (committed
bitmap budgeted; only the visible one keeps wet/pending layers warm).
- Pro: no mount/settle/reveal bridging; drawing on any visible page "just works";
  kills a whole class of page-switch bugs.
- Con: must cap total committed-bitmap memory across N pages (budget per page,
  evict off-screen pages to their lower-res cached image); more views in the scroll
  view; geometry publishing still required.

**Recommendation:** ship **Option A first** (smallest diff, reuses the engine
skeleton), keep **Option B** as a follow-up once vector rendering is proven, since B
is the design that finally removes the page-switch hacks. Either way: **reuse
`DocumentScrollView`'s scroll/zoom/center/geometry code wholesale**; only the
"what's mounted on the active page" and "what the cached image is rendered with"
change.

---

## 5. The hard integrations

### 5.1 Page backgrounds (paper / template / PDF)

Already solved by `PageRenderer.drawBackground` / `PageContainerView.draw` /
`PDFTemplateRenderer`. The custom ink view must be **transparent over** the
background (today `VectorInkView` fills white in `draw(_:)` and is `isOpaque=true`
— change to clear/non-opaque so the container's paper/PDF shows through, exactly
like `InkCanvasView.backgroundColor = .clear`). The active page's PDF zoom-raster
path (`updateRasterScale`, ~819) is independent of ink and carries over unchanged.

### 5.2 Media overlay

Media is SwiftUI, positioned by `transform(forPage:)` and tapped via
`onCanvasFingerTap` (page coords). It does **not** touch the canvas. Keep
`onCanvasFingerTap` firing in page coordinates (custom view → divide by `inkScale`
or by its own scale) and media is unaffected. Render order (`PageRenderer.draw`:
media below ink) is already encoded in the cached-image renderer.

### 5.3 Lasso select / move / rotate

Today: pencil pan captures loop points (canvas coords) → `onLassoComplete` →
`StrokeSelector` builds a `StrokeSelection` of **PKStroke indices**; the engine
`liftStrokeSelection` removes them from `canvas.drawing`, the overlay previews a
snapshot, and `commit/duplicate/copy/cut/deleteStrokeSelection` apply
`StrokeSelector.applyTransform` (rotation/scale/translation) back onto a `PKDrawing`.

Two paths:
- **If keeping `PKStroke` as the model** (recommended early): lasso works *unchanged*
  — `StrokeSelection`, `StrokeSelector`, clipboard, all keep operating on `PKDrawing`;
  only the *rendering* of the result is the custom view. This is a strong argument
  for keeping PK as the data model and using the custom engine purely as a renderer
  (§6 Phase 1–2).
- **If moving to `VectorStroke`**: reimplement hit-testing (point-in-polygon over
  stroke points), `applyTransform` (affine over points), and the clipboard
  (`strokeClipboard` becomes `[VectorStroke]`). Significant, do last.

The marching-ants loop overlay reads `lassoPoints` + `canvasTransform`; keep
publishing loop points in the same canvas-coordinate space.

### 5.4 Circle & Ask region capture

`AskLassoOverlay` captures a screen rect → page rect via `transform.toPage`;
`sendCircleAsk` renders the page region from the **persisted `Snapshot`** (not the
live canvas) and crops. **As long as `drawingData` stays a valid PK blob (§3.2),
this is unchanged.** No custom-engine work needed beyond keeping the blob current
(commit pending ink before capture — `commitPendingInk()` already exists).

### 5.5 AI answer-in-ink insertion

`AIModes.writeInk/answerInInk/drawSketch` build `[PKStroke]` via `InkWriter` and
append to `canvasController.canvasView!.drawing`, with undo registration and a
`1/canvas.transform.a` rescale. This is the **tightest PencilKit coupling** in the
app.

- **Phase-1/2 (PK live model):** untouched — AI writes into the live PKCanvasView.
- **Full vector model:** need an `appendVectorInk([VectorStroke])` on the custom
  view, plus `InkWriter` output → `VectorStroke` (InkWriter already produces
  polyline contours, so this is mechanical), undoable via the custom `UndoManager`,
  and `MarginLaneView` (which renders the *preview* of the same strokes) must read
  the same generator. Keep `inkScale` handling consistent (or 1).

### 5.6 OCR / render-for-AI / thumbnails / export

All read `Page.drawingData` through `PageRenderer` — **off the live canvas entirely**.
They keep working with **no change** provided the PK projection blob is maintained
(§3.2). This is the strongest reason to keep `drawingData` populated. `PKDrawing.image()`
must run on main on iOS 26 (`PageRenderer.inkImage`) — already handled; the vector
projection inherits that. (Optionally, later, give `PageRenderer` a *vector* draw
path that bypasses PK for sharper export — but that is an optimization, not required.)

### 5.7 Dark-mode ink adaptation

The engine pins the live canvas to `.light` and maps storage↔display via
`InkColorAdapter` (`displayIntoCanvas`/`canonicalFromCanvas`), re-adapting on
`appearanceChanged()`. The custom renderer draws literal colors, so:
- Store canonical (light) colors in `vectorInkData`.
- At display time, map each stroke's color through `InkColorAdapter.displayColor`
  before rendering (black → near-white on dark paper).
- On appearance flip, re-render the committed bitmap with the new mapping (cheap)
  and re-render cached page images — same trigger as `appearanceChanged()`.
- `PageRenderer` already does the same mapping for cached/export renders, so the
  background path is consistent.

---

## 6. Phased, flag-gated migration

Flag: `UserDefaults "settings.canvas.customInk"` (default off), read once at engine
construction like the existing `settings.canvas.smoothInk`. Add a Settings toggle
next to "Custom ink lab (preview)". Every phase is independently shippable and
revertible by the flag.

### Phase 0 — Scaffolding (no behavior change)
- Promote `VectorInkView` out of the lab into a reusable component; add the
  `VectorStroke` model + Codable; add `PKDrawing ↔ [VectorStroke]` converters with
  round-trip unit/visual tests.
- Add `Page.vectorInkData` (+ version) as an **optional** attribute (CloudKit-safe).
- **Test:** existing app builds and runs identically; converters verified on real
  notes (open a note, convert PK→vector→PK, diff renders).

### Phase 1 — Custom renderer for INACTIVE pages only (lowest risk) ⟵ recommended start
- Render each page's *cached image* (the inactive-page bitmap) with the custom
  vector renderer reading the page's `PKDrawing` (converted on the fly), instead of
  `PageRenderer`'s `PKDrawing.image()`. Background still from `PageRenderer`.
- Live editing stays 100% PencilKit. No data-model write changes.
- **Why first:** proves the vector renderer's sharpness/perf against real notes with
  *zero* input, lasso, AI, or persistence risk. Reversible instantly.
- **Test on device:** scroll a long note, zoom — inactive pages must be sharp and
  pixel-faithful to the PK render; no perf regression.

### Phase 2 — Custom renderer for COMMITTED ink on the active page
- On the active page, draw committed strokes with the custom view (transparent over
  the paper container), but **keep `PKCanvasView` mounted as the input + live wet
  stroke + undo + lasso + AI source of truth**, hidden or alpha-blended. On commit,
  feed the new `PKStroke` into the vector renderer.
- This is the "sharp at zoom" win for the page you're editing, still on the PK model.
- **Test:** write, zoom in deep — committed ink stays crisp (the prototype's core
  promise) while everything else (lasso, AI, undo, shapes) behaves exactly as today.

### Phase 3 — Custom input + undo (replace the live PKCanvasView input)
- Route touches through `VectorInkView`; own `UndoManager`; wire `canUndo/canRedo`,
  multi-finger undo/redo, eraser cursor, pen-tracker debug, keyboard-suspend.
- Persist **both** `vectorInkData` (master) and the PK projection into `drawingData`
  (§3.2) on the debounced save, via the unchanged `onDrawingChanged(Int, PKDrawing)`
  callback (pass the projection) — editor save path untouched.
- Implement tool mapping from `ToolState` (color/width/highlighter/pencil/ruler),
  `pencilOnly`, one-finger-draw vs two-finger-pan.
- Keep lasso + shape + AI **still on a parallel PKDrawing** mirror if needed, OR gate
  those features off under the flag until Phase 4–5.
- **Test:** full draw/erase/undo/redo/dark-mode/save/reopen cycle; verify
  `drawingData` projection renders identically in export + thumbnails + OCR.

### Phase 4 — Lasso, shapes, clipboard, insert-space on the vector model
- Reimplement `liftStrokeSelection`/`commit`/`duplicate`/`copy`/`cut`/`delete`,
  `pasteStrokes`, `insertSpace`, `beginStrokeEdit`/`endStrokeEdit`,
  `setLassoGestureActive`, auto-shape recognition (`ShapeRecognizer` adapter +
  hold-snap recognizer) against `VectorStroke`.
- **Test:** each gesture independently — lasso move/rotate/scale, shape snap + node
  edit, cut/paste cross-page, insert-space.

### Phase 5 — AI ink insertion on the vector model
- `appendVectorInk` + `InkWriter → VectorStroke`; undoable; `MarginLaneView` preview
  parity; Circle & Ask unaffected (reads blob).
- **Test:** answer-in-ink, draw-sketch, guided-mode write, with avoid-overlap.

### Phase 6 — Make custom engine the default; PKCanvasView removed from the live path
- Flip the flag default; keep PK projection write for interop/CloudKit/old devices.
- Optionally add a vector export path in `PageRenderer`.
- **Test:** full regression on real notes, CloudKit round-trip to a second device
  (which may still be on PK), export/share.

---

## 7. Risks, unknowns, open questions

**High**
- **Stroke-model fidelity loss.** `PKStroke` carries pressure/azimuth/altitude/force,
  ink type, mask, and Apple's variable-width tessellation. `InkSample` is
  location+width only. A full swap *degrades* existing ink and breaks lossless
  round-trip. → Mitigation: keep `drawingData` as the canonical interop blob; make
  `vectorInkData` the additive master; never delete the PK blob.
- **CloudKit / multi-device.** A second device (or older build) reads `drawingData`
  via PencilKit. The vector blob is invisible to it. → The PK projection must always
  be written and must be a faithful render. New attributes must be optional/additive
  (`NSPersistentCloudKitContainer` rejects non-additive schema changes; persistent
  history is on).
- **AI subsystem coupling.** `AIModes`, `InkWriter`, `MarginLaneView`, the tutor
  preview, all assume `PKCanvasView`/`PKStroke`. This is the largest single
  reimplementation surface; sequence it last (Phase 5) and keep PK live until then.

**Medium**
- **`inkScale` coordinate contract leaks into the editor.** Snap metrics, AI stroke
  scaling, lasso/paste/insert-space, overlay transforms all multiply/divide by
  `controller.inkScale`. The custom engine gets sharpness from re-rasterization, so
  it *can* run at `inkScale = 1` — but then every one of those sites must be audited
  (they're no-ops at ×1, but the contract must be deliberate, not accidental).
- **Eraser semantics differ.** Custom eraser is whole-stroke (drop the stroke); the
  app ships *both* pixel and object erasers (`eraserPixel`/`eraserObject`). Pixel
  erase (split a stroke) is non-trivial on vectors — needs stroke-splitting geometry.
- **Off-main bake races.** The prototype's `bakeGeneration`/`isBaking`/`flush`
  machinery is subtle; multi-page + reparenting + appearance flips add more
  invalidation cases. Needs careful generation-guarding per page.
- **Memory budget across pages** (Option B) — must cap committed bitmaps and evict
  off-screen pages.
- **Undo parity.** The app leans on `PKCanvasView.undoManager` for AI ink, shapes,
  lasso, paste, insert-space — all register undo against it. A custom `UndoManager`
  must replicate every registration site (many) with identical grouping.

**Low / mechanical**
- Pen-hold Circle & Ask trigger, dismiss-tap intercept, keyboard-suspend, eraser
  cursor, debug pen tracker — straightforward to port; already isolated gestures.
- Shape recognition adapter — `ShapeRecognizer` takes `PKStroke`/points; a
  `VectorStroke→points` shim is trivial.

**Open questions for the owner**
1. Is **PK-as-model, custom-as-renderer** (Phases 1–2, possibly permanent) an
   acceptable end state? It captures the sharpness/perf win with a fraction of the
   risk and keeps every PK-dependent feature free. The full vector model (Phases 3–6)
   is only required if you want to *drop PencilKit entirely* (e.g. for a custom
   pen feel PencilKit can't give, or to escape the iOS 26 PK rendering bugs).
2. Do we need pixel-level erase, or is whole-stroke erase acceptable for v1 of the
   custom engine? (Affects eraser scope a lot.)
3. Is `inkScale` going to 1 under the custom engine, or do we preserve the
   supersample contract to avoid auditing the editor's coordinate math?
4. Acceptable to keep writing the lossy PK projection forever (interop tax), or do
   we plan a future where `drawingData` is dropped and all readers move to vector?

---

## 8. First concrete deliverable

**Phase 0 + Phase 1**, behind `settings.canvas.customInk`:
1. Extract `VectorInkView` into a reusable renderer; make it transparent over a
   background; add `PKDrawing → [VectorStroke]` import.
2. Add optional `Page.vectorInkData` (no behavior depends on it yet).
3. Swap *inactive-page cached image* rendering to the vector renderer when the flag
   is on; everything else stays PencilKit.
4. Verify on device against real notes: sharpness, pixel-parity vs PK render, scroll
   + zoom perf, and that flipping the flag off restores byte-identical behavior.

This proves the engine end-to-end against production data with effectively zero risk
to input, persistence, AI, lasso, or CloudKit — and informs Open Question #1 before
any irreversible model work begins.
