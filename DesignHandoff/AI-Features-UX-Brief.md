# StudyInk — AI Tutor UX Design Brief

You are a senior product designer. **StudyInk** is an iPad handwriting note app for
students solving math/science problems (Calculus, Discrete Math; often Hebrew
problem statements with LaTeX). The student writes with an Apple Pencil on a
PencilKit canvas; an **AI Tutor** watches and helps. Your job: **redesign the AI
tutoring experience** so it feels like a calm, expert tutor sitting beside the
student — present when wanted, invisible when not — with one coherent visual
language and clear, learnable affordances.

This brief explains every AI surface that exists today: what it does, **when it
appears**, how it looks, and how you interact with it. Use it to propose a better
orchestration and visual system. Treat the current behavior as a starting point to
improve, not a constraint. Where it helps, redesign the triggers ("when should
what"), not just the pixels.

---

## Design language (today)

- **Accent of "you" (the student):** the theme's primary color = your ink, selection.
- **Accent of "AI" (the tutor):** a warm **amber** (`aiAccent`). Every AI thing
  uses it: glyphs, suggestion ink, cards, the ✦ sparkle avatar.
- **Motion:** a slow "breathing" glow/pulse signals AI activity (thinking, a live
  suggestion). It's used a lot — evaluate whether that's calm or noisy.
- Surfaces float over the live canvas; they must **never block drawing** when the
  student wants to write, and must scroll/zoom locked to the page they annotate.
- The app is **handwriting-native**: the tutor writes math as real handwriting (a
  "Noteworthy" hand font with true 2-D fractions), not typeset text, whenever it
  puts math on the page.

### Where things live on screen (the zones)

The editor is: a full-page canvas, a vertical **tool rail on the LEFT**, a small
floating **header top-LEFT** (back, note title), an **action cluster top-RIGHT**
(undo/redo, mic, ⋯, duplicate, **"AI Tutor"** button), a **page-navigator strip on
the RIGHT edge** (page x/y), and a **"Guided Mode" pill bottom-LEFT**. Everything
the AI shows must respect these:

- **Inline (on the line):** next-step suggestion ink, accepted ink, the result a
  correction writes. Lives in the page's content flow, scrolls/zooms with the ink.
- **Left margin lane:** the per-line glyphs (✓ correct, ~ correction, ? hint) sit
  just left of the equation they're about.
- **Right margin:** the "grade my answer" pill parks here, at the last line's
  height (kept clear of the page-navigator strip).
- **Floating card near the line:** the step card ("why"), the unfolded grade-note —
  parked toward the trailing side at the glyph's height, never under the strip.
- **Panel (center, draggable):** the AI Tutor chat. The one heavy surface.
- **Corner badge:** a breathing ✦ sparkle (top-right area) signals "AI is working."

A good redesign assigns **each kind of help to exactly one zone** and keeps the
zones from competing for the same pixels.

---

## The AI surfaces

### 1. AI Tutor chat (the "bubble")
- **What:** a floating chat panel. Ask anything about the work; answers render as
  rich text + real 2-D math, RTL-aware.
- **When:** opened explicitly (the "AI Tutor" button, top-right). It is the only
  surface that is a "panel/chat"; everything else is in-context on the page.
- **Design tension:** it's the heaviest UI. We are deliberately moving *away* from
  it for proactive help (see below) — the page-anchored surfaces should carry most
  interactions; the chat is for open-ended questions.

### 2. Circle & Ask (a pen tool)
- **What:** circle any region of the page, then ask about exactly that.
- **When:** select the Circle-&-Ask tool, or hold the Pencil still ~1s. The AI
  reads the circled region + page context.

### 3. Answer in Ink
- **What:** the tutor writes the answer/correction **as handwriting** onto the page
  in amber, placed in a clear gap so it never lands on the student's work.

### 4. Explain
- **What:** explains the current page or a tapped concept (a tap-to-define glossary
  also exists for named theorems/methods).

### 5. AI sketch
- **What:** the tutor can draw a diagram/graph on the canvas.

### 6. Ambient Tutor / "Guided Mode" — the proactive layer (the heart of this brief)

A **sensitivity** setting governs how proactive the tutor is:
- **off** — silent.
- **subtle** — present but no pop-ups.
- **helpful** (default) — proactively suggests/nudges as you work.

While you write, these can appear **on the page** (not in the chat):

**a) Next-step suggestion ("ghost")** *(Helpful only)*
- **When:** you write a real handwriting stroke (not a doodle/diagram line — a
  size + straightness filter excludes axes/circles/underlines) and **pause ~4s**.
- **Look:** the predicted next line, drawn as faint **handwriting** (the same
  strokes that would be written), inside a **dashed amber box** so it reads as a
  *suggestion*, placed exactly where it would be written (continuing your line, or
  on the next line).
- **Interact:** tap the ink (or flick right) → it's written as real ink. Flick
  left → dismiss. A small **"?"** beside it opens a **step card** (the "why" + the
  worked steps that lead to it).

**b) "Grade my answer" glyph**
- **When:** you finish writing and pause ~3.5s (any sensitivity).
- **Look:** a breathing amber "Check my work" pill parks in the right margin at
  your last line.
- **Interact:** tap → grades the whole page (see c). A small × dismisses; writing
  again clears/re-arms it.

**c) Check my work / grading**
- **What:** grades the page and **streams margin glyphs** anchored to each line:
  **✓** (verified correct, passive) and a **~ squiggle** (gentle correction).
- **Interact:** tap a correction glyph → a small amber "note" card unfolds with the
  explanation, a **"Fix it"** action (writes the correction in ink), and a **"Show
  why"** action (opens the step card — worked steps, *not* the chat).
- Glyphs are removed automatically if you erase the ink they point to.

**d) Hint "?" glyphs**
- **When:** the watcher detects you're **stuck / made an error / skipped a step**.
- **Look/Interact:** a "?" glyph by the relevant line; tapping highlights the line
  and opens the **step card** (worked steps, not the chat).

**e) The step card (shared "why" UI)**
- One reusable inline card: a "✦ Why" header, the one-line reason, then **numbered
  worked steps** (each step = *the action* → *the resulting expression*), RTL-aware,
  with a dismiss. Used by the ghost "?", the grade-note "Show why", and the hint
  "?". Replaces opening the chat for explanations.

---

## "When should what" — the orchestration problem (the core ask)

Today, on an idle pause after writing, **multiple things can fire at once** — the
next-step ghost AND the grade glyph — plus hint glyphs and, after a check, a field
of ✓/~ glyphs. There is no single arbiter deciding what the student needs *right
now*. This is the main thing to fix. Consider:

- **Intent inference:** mid-derivation vs. "I think I'm done" vs. "I'm stuck" vs.
  "I'm just doodling/annotating a graph." Each wants a different response (next
  step / grade / hint / nothing). What signals distinguish them, and what should
  appear for each?
- **One thing at a time?** Should the proactive layer show at most one suggestion,
  with a clear hierarchy (e.g. error > stuck > next-step > grade-offer)? How does
  the student get to the *others* if they want them?
- **Cadence & restraint:** how long to wait; how often to re-offer; when to stay
  silent (the tutor should err quiet). How do dismissals teach it to back off?
- **End-of-problem:** detecting a final answer line to offer grading at the right
  moment, instead of after every pause.
- **Spatial language:** what lives *inline* (next-step ink, grade result on the
  line) vs. in the *margin* (glyphs, the grade offer) vs. as a *card* (why/steps)?
  Define a consistent zoning so the page never feels cluttered.
- **State & persistence:** when do glyphs/cards clear (erase the ink → glyph gone
  already; page change; new check; explicit dismiss)? What persists across sessions?

## Clear paths — what should happen, moment by moment

Design these as coherent, **non-overlapping** flows. For each: the **trigger**, then
**what shows and WHERE** (which zone), the **interaction**, and how it **resolves**.
These are the target paths to make crisp — today they collide; your job is to give
each a clean lane.

1. **Student writes a step, then pauses (mid-problem).**
   Trigger: a handwriting stroke settles ~a few seconds, more work clearly remains.
   → Show: at most the **next-step suggestion** (inline, where the next line goes) —
   *or nothing* if confidence is low. Not the grade pill at the same time.
   Interaction: tap/flick-right keeps it (writes ink); flick-left or keep writing
   dismisses. Resolve: clears the moment they write or move on.

2. **Student writes what looks like a final answer, then pauses.**
   Trigger: a line that reads as a result/conclusion + a longer pause.
   → Show: the **"grade this" offer** (right margin, at that line) — *instead of* a
   next-step suggestion. Interaction: tap → grade. Resolve: offer replaced by the
   ✓/~ results; × or new writing dismisses.

3. **Student is stuck** (rewrites/erases the same line, no progress, long pause).
   → Show: a single **hint** (left-margin "?" at that line), not a full answer.
   Interaction: tap → the **step card** (why + worked steps) by the line. Resolve:
   persists until they progress, re-check, or dismiss.

4. **Student makes a clear error** (only knowable after a check, or a high-confidence
   live catch). → Show: a **~ correction glyph** on that line. Tap → grade-note card
   with **Fix it** (writes the correction inline) and **Show why** (step card).
   Never silently "auto-correct" the page.

5. **Student doodles / sketches a graph / underlines.** → Show **nothing**. The
   tutor must read this as not-an-answer and stay silent (define the UX signal for
   "this stroke was a diagram," beyond the current size/straightness heuristic).

6. **Student asks "why" / taps "show why"** (from a suggestion, a correction, or a
   hint). → Show: the **step card** by the relevant line — never the chat panel.
   Card streams a loading state, then the reason + numbered worked steps; × dismiss.

7. **Student accepts a suggestion.** → The faded dashed preview is replaced by
   **committed ink** in the SAME place (no jump). Any "?" for it goes away. The next
   pause may offer the next step from there.

8. **Student dismisses repeatedly / ignores offers.** → The tutor should **back off**
   (longer waits, fewer offers) — design how dismissals teach restraint, and how the
   student re-summons help on demand when they do want it.

9. **Student erases the ink a glyph points to.** → The glyph **disappears**
   automatically (already implemented) — keep this invariant across all page-anchored
   AI marks (a suggestion/card whose line is gone should clear too).

10. **Student opens the AI Tutor chat.** → The chat is for **open-ended questions**;
    proactive/contextual help stays on the page. Decide what (if anything) the chat
    should surface that the page surfaces can't.

## Known pain points to solve

1. **Clutter / competition** between the ghost, the grade glyph, and hint glyphs on
   the same pause.
2. **Discoverability** of gestures (flick to keep/dismiss, tap-the-ink-to-accept) —
   are they learnable? Should there be a first-run teach?
3. **Too much motion** — breathing/pulsing on several elements at once.
4. **"Is this mine or the AI's?"** — keep the line between a *suggestion* (faded
   handwriting + dashed box) and *committed* ink unmistakable, including once it's
   accepted.
5. **Distinguishing a doodle/graph from real work** so the tutor doesn't fire on a
   sketch (currently a heuristic on stroke size/straightness — propose the UX, not
   just the threshold).
6. **Sensitivity is a blunt 3-way switch** — is there a more humane model (e.g. the
   tutor naturally quieting as the student progresses, or per-gesture opt-in)?

## What to produce

1. **An orchestration model** — a clear decision logic for *when each AI surface
   appears*, with priorities and conflict rules (the "when should what"). A simple
   state diagram or table is ideal.
2. **A unified visual + motion system** for the AI layer (glyphs, suggestion ink,
   cards, the offer pills) — one language, calmer motion, clear suggestion-vs-ink
   distinction.
3. **Redesigned flows** for: writing → next-step suggestion; finishing → grading;
   getting stuck → hint; asking "why" → steps. Show the happy path and the
   dismiss/ignore path for each.
4. **Annotated mockups** (page-anchored, on a realistic math page) showing exact
   placement, hierarchy when multiple things *could* show, empty/quiet states, and
   the accept/dismiss affordances.
5. Call out anything that should move **out of the chat** and onto the page, and
   anything currently on the page that should be quieter or removed.

Optimize for a student who is concentrating: **calm, glanceable, never in the way,
and obviously helpful the moment they want help.** Verify current behavior in the
running app where this brief is ambiguous.
