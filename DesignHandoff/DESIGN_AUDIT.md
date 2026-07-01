# Design QA Audit — AI Refinement Pass

Date: 2026-07-01 · Branch: `feature/ai-refinement-pass`
Acceptance criteria: `StudyInk/AI/AITokens.swift` (codified from `design_handoff_conote_ai` §3/§7/§8)
and `StudyInk/App/DesignTokens.swift` (Foolscap `DS.*`, source: DesignHandoff/README.md).

> Note on the task prompt's assumed spec: the prompt cites "spring response 0.3, damping 0.7,
> 200ms entrances". The repo's actual specs differ and win: AI surfaces use `AITokens.Motion`
> (settle 0.3/1.0, unfold 0.4/0.85, dismiss 0.2s easeOut, ONE breathing element max) and app
> chrome uses `DS.Motion` (bubbleAppear 0.32/0.78 etc.). Flagged, not changed.

## Verdicts

| # | Area | Finding | Severity | Action |
|---|------|---------|----------|--------|
| 1 | AI views · motion | ~25 ad-hoc `.spring/.easeOut/.easeIn` literals in AI/ (MarginLaneView, MarginThreadView, GhostTraceLayer, QuizView…) instead of `AITokens.Motion.*` | Med | FIX — route through tokens where semantics match (dismiss/unfold/settle/ghostAppear) |
| 2 | Tutor surfaces · color | Mixed token systems: `AppTheme.current.aiAccent` + `SemanticColor.*` used inside the 5 tutor surfaces (MarginLaneView ×8, etc.). Handoff: tutor surfaces pull **every** color from AITokens ("zero hardcoded hex in views", paper never theme-tinted) | Med | FIX in the 5 handoff surfaces; legacy surfaces (QuizView, GuidedMode card, panel) flagged for later |
| 3 | App chrome · color | Hardcoded `#FFD60A` gold in DesignComponents (×2) + SettingsView gold dot; hardcoded paper in Canvas/InsertSpace | Low | FIX — add `DS`-level accent token / reuse SemanticColor paper |
| 4 | AI chrome · tap targets | Several controls at 22–26pt without a ≥44pt hit area (AIBubbleView ×4, AIPanelView, GhostTraceLayer "?", ladder chevrons). Spec: `Lane.tapTarget = 44` "≥44pt via padding" | Med | FIX — `.contentShape` + padding to ≥44pt hit area, visual size unchanged |
| 5 | Type | `Caveat` and `Gveret Levin AlefAlefAlef` are NOT bundled (silent fallback to system). Fraunces IS bundled (variable) | Med | FLAG — needs font files (OFL; task #61). Fallback is acceptable interim |
| 6 | Dark mode | AITokens is a fixed warm-paper palette; AI cards stay light in dark mode | Info | SPEC-INTENTIONAL ("paper — NEVER theme-tinted"). Verified readable; not a bug |
| 7 | Legacy AI surfaces | GuidedMode.swift keeps its own 6-color ink palette (pre-handoff); AIModes default ink `#0A84FF` | Low | FLAG — palette feeds canvas ink variety, not chrome; leave until guided-mode rebuild (Part 3) |
| 8 | RTL · bidi | **No FSI/PDI directional isolates anywhere.** Math/latin runs inside Hebrew sentences rely on the platform bidi algorithm alone → scrambling risk (the "(VX-1) תוכן מיותר" class of bugs) | High | FIX in Part 2 — isolate math/number spans in prose rendering |
| 9 | RTL · chrome | Chat rows/cards RTL-align via per-string Hebrew detection (good), but: chips rows don't flip scroll direction; "Ask more" field doesn't flip send-button side; thread header order fixed LTR | Med | FIX in Part 2 |
| 10 | Spacing/radii | AI cards: 16pt radius (= DS.Radius.lg) ✓; chips/pills use Capsule ✓; paddings mostly 8/12/16 with a few 7/9/11 one-offs | Low | Spot-fix drift where touched; not a sweep |
| 11 | Motion · breathing | "At most ONE breathing element" — FindMistakePill breathes; TutorGlyph can breathe simultaneously while thinking | Low | FIX — suppress pill breathing while any other breathing surface is active |
| 12 | InkWriterPreview / CustomInkLab | Hardcoded dev-harness colors | Info | Ignore — dev-only surfaces, not shipped UI |

## Screen pass (light/dark/RTL)

- **Library / Settings / Template picker**: token usage clean apart from #3. Dark OK (SemanticColor). RTL: standard SwiftUI mirroring, no custom geometry — OK.
- **Note canvas + toolbar**: colors via InkColorAdapter/AppTheme ✓ (recent work). Eraser cursor, width presets ✓.
- **AI bubble (margin thread)**: RTL rows fixed this session; remaining = #9 (chips/field mirroring) and #1 (motion tokens).
- **Guided ladder / diagnostic / ghost / selection rail**: #1, #2, #4 apply; diagnostic Hebrew quality is a prompt issue (fixed separately), not layout.
- **Quiz mode / side panel**: legacy design system (pre-handoff) — flagged #2/#7, full restyle out of scope for this pass.

Each FIX lands as its own commit on this branch; FLAG items are listed in the PR description.
