# Production Visual QA

This checklist covers the final production-polish pass without changing the app's
navigation model or the main, Settings, or Add Download window dimensions.

## 1. Pixel alignment

Validate on a Retina display at normal macOS scaling and, when available, on a
1x/external display.

- Hero URL field: link icon, placeholder baseline, Paste, and Download controls
  remain vertically centered with no clipped leading text.
- Download rows: thumbnail top edge, title baseline, status line, and trailing
  action column remain visually aligned.
- Recent rows: title/domain stack stays centered against the thumbnail; the
  status/action region and remove slot keep a stable trailing edge.
- Shared primary/secondary/ghost buttons keep consistent label height whether
  the label is text-only or icon + text.
- Focused fields show a complete 2 pt accent focus edge without clipping.

## 2. Appearance matrix

Test the app with macOS set to Light and Dark while Siphon is set to System,
then force Light and Dark from Siphon Settings.

Expected:

- System follows the current macOS appearance immediately.
- Status text/icons remain readable in Light appearance; saturated P3 colors
  remain reserved for fills, glow, and motion where appropriate.
- Glass surfaces, separators, field edges, and inactive-window content remain
  distinguishable without replacing translucency.
- Increase Contrast strengthens custom borders without changing layout.

## 3. Pathological content fixtures

Use strings at least as long as these categories:

- Title: 180+ characters including punctuation and emoji.
- URL: 250+ characters with query parameters and percent-encoding.
- Save path: 200+ characters with deeply nested folders.
- Playlist item: 140+ characters.
- Custom preset name: 100+ characters.
- Feedback/error text: 180+ characters.

Expected:

- Titles truncate at the documented line limit rather than pushing actions.
- URLs remain editable while fixed action controls retain their width.
- Paths truncate in the middle and expose the full value through Help.
- Playlist/preset names truncate at the tail and keep checkboxes/actions visible.
- Error/feedback descriptions truncate or wrap within their intended region.

## 4. State-transition matrix

Exercise a single download through:

fetching -> queued -> downloading -> processing -> completed

Also validate paused, failed/stopped, and file-exists states.

Expected:

- The ordinary trailing action slot remains stable between states.
- Progress presentation does not add/remove row height during active transfer
  transitions.
- Metadata/title position does not jump when the status badge or metrics change.
- Failed rows may expand for remediation content; file-exists may expand its
  intentional two-action conflict controls.
- Recent rows reserve their trailing remove slot so completion does not shift
  the preceding status region.

## 5. Motion tuning

Current production targets:

- Card hover: 1.012 scale, 2 pt lift, status-tinted 14 pt shadow.
- Hero drag target: 1.012 scale with the stronger dashed accent/glow treatment.
- Status segments (Downloading → Completed → Failed): only the Downloading
  segment animates, as a liquid fill tracking aggregate progress; it stops when
  nothing downloads, while Siphon is inactive, or with Reduce Motion. Other
  segments use a static tint and stay inside the group's rounded corners.
- The progress fill uses the display's 60/120 Hz sampling policy without
  changing animation physics.

Watch specifically for clipping while cards scale, shadow cut-off near scroll
container edges, sudden wave phase resets, and controls that move instead of
animating in place.

## Acceptance criteria

The pass is complete when the above matrix is clean in System/Light/Dark,
long-content fixtures do not move primary controls out of position, and the
normal download state sequence does not visibly change row geometry except for
the intentionally expanded error and file-conflict states.
