# grounding-lab

Measures how accurately a model can point at things on a real macOS screen —
without anyone hand-labelling a single screenshot.

Iris's pointing feature asks a model "where is the Create Key button?" and needs
a pixel coordinate back. Nobody knew how accurate that is on real macOS UIs, and
the whole pointing architecture depends on the answer. This tool produces that
number.

The trick is that macOS's accessibility tree already knows the exact rectangle
and human label of most controls. So it can generate the questions *and* the
correct answers automatically: walk the tree, and every button it finds becomes
one labelled example.

This is a lab tool. It is a standalone Swift package, it is **not** part of
`leanring-buddy.xcodeproj`, and nothing in it ships in the Iris app.

## Requirements

macOS 14+, Swift 5.9+, no third-party dependencies (Foundation, AppKit,
ApplicationServices, ScreenCaptureKit, CoreGraphics only).

Both **Screen Recording** and **Accessibility** permission are required. A
process launched from Terminal inherits Terminal's grants, so run it from a
terminal that already has both — that is the intended and easiest path. Both are
checked at startup and the tool exits with an explanation if either is missing,
because both failures otherwise produce *silently empty* results rather than
errors, and an empty dataset looks exactly like a broken walker.

## Running it

```bash
cd iris-macos/tools/grounding-lab
swift build

# 1. Build a labelled dataset from a real app (no human labelling involved)
.build/debug/grounding-lab capture --bundle-id com.apple.finder --out ./run1

# 2. Score the accessibility arm. Makes no API calls.
.build/debug/grounding-lab run --dataset ./run1/dataset.json --arm ax --limit 0

# 3. Score the model. Reads ANTHROPIC_API_KEY from the environment.
set -a; source /Users/you/publik/.env.local; set +a
.build/debug/grounding-lab run --dataset ./run1/dataset.json --arm claude --limit 10
```

`--frontmost` captures whatever app is in front instead of a bundle id.
`--model` selects the model (default `claude-haiku-4-5`).

### Cost control

`--limit` caps how many targets a run scores, defaulting to **40**; `--limit 0`
removes the cap. When a limit applies, the subset is evenly spaced through the
dataset rather than the first N, so a capped run does not score only the menu
bar.

The **estimated cost is printed before any API call is made**. The API key is
read from `ANTHROPIC_API_KEY` and is never logged, echoed, or written to any
output file.

## The three arms

| Arm | What it does | What its number means |
| --- | --- | --- |
| `ax` | Resolves each instruction against the **live** accessibility tree and answers with that element's centre. No API calls. | Near-perfect accuracy by construction. Its real output is **coverage** — the fraction of instructions it can answer at all. |
| `claude` | Sends the screenshot and instruction to Anthropic's computer-use tool and parses the coordinate back. | The actual grounding measurement. |
| `claude-verify` | Draws a crosshair at a proposed point and asks "is this on the X?", parsing yes/no. | Whether *checking* an answer is easier than producing one — which is the reason a cheap verifier might be worth having. |

`claude-verify` sends **two** probes per target: one on the real element
(correct answer: yes) and one on a decoy — a different target's centre (correct
answer: no). Without the decoy, a model that always says "yes" would score 100%.
It therefore makes `2 × targets` API calls, and reports probe accuracy,
true-positive rate and false-positive rate rather than an error distance, since
it never produces a coordinate.

## Reading the numbers

Per arm the tool reports **hit rate**, **median and p95 error distance**,
**p50/p95 latency**, **API calls made** and **estimated + actual cost**, prints a
comparison table, and writes `results.json`.

- **Coverage** and **hit rate** are reported separately because they answer
  different questions: *could the arm answer at all* versus *was the answer
  right*. An arm that answers three questions perfectly is not better than one
  that answers ten questions well.
- **Hit** = the predicted point lands inside the target rectangle padded by 8pt
  (`--hit-padding` changes this).
- **Error distance** = distance from the prediction to the **centre** of the
  target, in points. A wide control can be a hit with a large centre distance —
  a correct click on the left edge of a 300pt-wide column header is ~100pt from
  its centre. That is why both numbers are reported.
- Everything is in **points**, never pixels. The dataset records the display's
  `backingScaleFactor` and scoring normalises to points before comparing.

### Coordinate spaces

Getting these wrong makes every arm look equally bad and is the single most
likely cause of a wrong conclusion, so all conversions live in one file,
`CoordinateSpaces.swift`, with each boundary written down.

`dataset.json` is entirely in **display-local points**: origin at the top-left
of the captured display, Y growing downward, points not pixels. Accessibility
reports global top-left-origin points, so converting is a pure translation.
AppKit's bottom-left origin is deliberately never mixed in.

The trap worth knowing: the shipping `ElementLocationDetector` flips Y
(`displayHeight - y`) to hand AppKit a bottom-left point for the cursor overlay.
Copying that flip here would mirror every prediction. `results.json` stores every
raw model coordinate, so both interpretations can be scored offline from one real
run — on 8 answered Finder targets:

| Interpretation | Hits | Median error |
| --- | --- | --- |
| Top-left (what this tool does) | 6/8 | 4.5pt |
| Bottom-left flip (upstream cursor path) | 0/8 | 531.3pt |

A wrong flip does not look like a bug. It looks like a model that cannot point.

## Known limitations

- **Occlusion is not handled.** The tool scopes the walk to the app's menu bar
  and its frontmost window, which removes the worst case (a five-window Finder
  reporting controls from four buried windows at coordinates that contradict the
  pixels). But a window belonging to *another* application covering part of the
  target app, or a sheet or popover inside the same window, will still leave
  targets in the dataset that are not visible in the screenshot. A model is
  scored as wrong for not finding something it genuinely cannot see.
- **AX-only ground truth is the real limitation.** The benchmark can only score
  where accessibility already sees. Canvas-drawn UI, custom-rendered controls,
  game and video content, images, and anything an app fails to expose are
  invisible to it — and those are exactly the cases where vision-based pointing
  matters most. A good score here does not mean pointing works everywhere; it
  means pointing works on the subset that needed it least.
- **Single display.** One display is captured per dataset — the one containing
  the target app's frontmost window. Multi-monitor coordinate mapping is not
  exercised.
- **The `ax` arm reads the live tree, so it drifts.** It must be run while the UI
  is still in the state it was captured in. Measured back-to-back with `capture`
  it reports 100% coverage; on the same dataset after the Finder window changed,
  coverage fell to 44%. That is drift in the machine's state, not a property of
  accessibility. Run `capture` and `--arm ax` together.
- **Only interactive roles are targets.** Buttons, links, checkboxes, radio
  buttons, menu items, text fields, pop-ups, tabs, sliders and similar (the full
  list is in `AccessibilityTreeWalker.interactiveRoles`). Containers and static
  text are excluded.
- **Ambiguity is dropped, in both directions.** One label appearing in several
  disjoint places is not a question with one right answer, so it is removed.
  Several different labels on identical rectangles is broken ground truth — this
  is how hidden controls appear, e.g. Finder instantiating seven tag radio
  buttons per row inside a closed popover, all at the same placeholder rect — so
  those are removed too.
- **Screen sleep breaks capture.** ScreenCaptureKit reports zero displays while
  the screen is asleep even with permission granted. The error message says so.

## Findings worth knowing before you extend this

Discovered against the live API while building the tool; each is handled in code
with a comment explaining why.

- **The computer tool version is model-specific.** `claude-haiku-4-5` rejects
  `computer_20251124` (which the shipping detector hardcodes) and needs
  `computer_20250124` with the older `computer-use-2025-01-24` beta header.
- **`max_tokens: 256` truncates Haiku mid-preamble.** The shipping detector's
  value made the model hit `stop_reason: "max_tokens"` before it emitted its tool
  call, which the harness would otherwise have scored as "could not find it".
  This tool uses 1024.
- **Haiku opens with the `screenshot` action** unless the prompt states the
  screenshot is already attached, because a computer-use tool normally implies an
  agent loop. That alone accounted for 7 of 10 non-answers.
- **A `scroll` action also carries a `coordinate`.** It is where to put the
  pointer before spinning the wheel, not where the element is. Only pointing
  actions are accepted; counting scroll anchors would have inflated both coverage
  and error.
- **Declaring the computer tool costs ~1,400 input tokens** of tool-definition
  overhead per call, on top of the image and prompt. The cost estimate includes
  it; without it the pre-flight estimate ran 40% low.
