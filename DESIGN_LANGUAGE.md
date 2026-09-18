# Siphon Design Language

This document is the visual and interaction source of truth for Siphon. New UI
should feel like a calm, native macOS utility: focused on the next download,
clear about state, and expressive through restrained liquid surfaces rather than
decoration for its own sake.

## Product character

- Calm and purposeful: one obvious primary action, low visual noise, and clear
  progress or next steps.
- Native macOS first: use standard windows, split views, toolbars, menus,
  controls, keyboard behavior, and accessibility semantics before custom chrome.
- Technical but approachable: Geist typography and compact metadata support a
  data-heavy workflow without making the interface feel like a terminal.
- Liquid, not glossy: translucency, soft gradients, and motion should suggest a
  surface of water. They must preserve contrast, hierarchy, and legibility.

## Source of truth in code

- `Siphon/Extensions/View+Compatibility.swift`
  - `SiphonTheme`: colors, spacing, radii, surfaces, borders, badges, and button
    styles.
  - `SiphonAnimation`: shared motion timing for fluid, hover, bouncy, and snappy
    interactions.
  - `siphonWindowBackground()`: adaptive root surface with a Reduce Transparency
    fallback.
- `Siphon/Extensions/Font+Geist.swift`: Geist and Geist Mono registrations plus
  semantic typography roles.
- `Siphon/Views/Components/LiquidWaterWaveView.swift`: the restrained organic
  ambient motion used in status controls.

Do not introduce a second palette, spacing scale, radius scale, animation scale,
or glass implementation in a feature view. Add a token to the shared source of
truth only when the value is genuinely reused or has semantic meaning.

## Visual system

### Color

- Use `Color.primary`, `Color.secondary`, and AppKit semantic colors for text and
  system states.
- Use `SiphonTheme.accent` and `SiphonTheme.primaryGradient` for the primary
  action and focused input states.
- Use semantic status colors only for status meaning:
  - downloading: blue
  - queued: amber
  - completed: green
  - failed/stopped: red
- Accent color is not a general-purpose decoration. If every icon is tinted,
  nothing communicates priority.
- Preserve readable contrast in both Light and Dark appearances and when Reduce
  Transparency is enabled.

### Color gamut and dynamic range

- Author Siphon-owned accent, gradient, status, and source-brand colors in
  Display P3. Native/system semantic colors remain system-managed.
- Treat wide color gamut and HDR as separate concerns. P3 is the normal authored
  color space; ordinary app chrome remains SDR even on EDR/HDR displays.
- Use elevated dynamic range only for genuine HDR media. HDR thumbnails shown
  beside SDR UI use constrained high dynamic range rather than boosting the
  surrounding interface.
- Never use HDR/EDR luminance as a decorative glow or hover treatment.
- Let ColorSync map P3 colors to narrower-gamut displays rather than maintaining
  a parallel hand-tuned sRGB palette.

### Typography

- Geist is the default UI face; Geist Mono is reserved for counts, URLs, paths,
  versions, commands, and other machine-readable values.
- Prefer the semantic `Font.siphon*` roles when a role exists. Use
  `Font.geist(_:weight:relativeTo:)` for a new role or a deliberately distinct
  display treatment.
- Keep hierarchy compact: one strong title, one supporting line, and metadata
  only where it helps a decision.
- Custom fonts must remain Dynamic Type-aware through `relativeTo`.

### Layout and spacing

- Use the 4/8pt rhythm represented by `SiphonTheme.spacing*`.
- Use `radiusControl` for controls and inputs, `radiusCard` for content cards,
  and `radiusSheet` for modal/sheet containers.
- Prefer adaptive proposed-size layout and `maxWidth: .infinity` over screen
  coordinates or fixed geometry calculations.
- Keep primary actions in the content and toolbar; do not hide essential actions
  behind hover-only behavior or gestures.

### Surfaces and depth

- Root windows and utility surfaces use `siphonWindowBackground()`.
- Content cards use `SiphonTheme.cardBackground` and matching border helpers.
- Interactive status/navigation surfaces may use `siphonGlassSurface()`, which
  opts into native `Glass.regular.interactive()` on macOS 26+ and preserves the
  adaptive Siphon material fallback on macOS 15–25.
- Inset fields use `SiphonTheme.fieldBackground` and `fieldBorder`.
- Controls use the shared Siphon button styles or the native macOS bordered
  styles when they better express platform behavior.
- Keep the hierarchy shallow: root surface → card → inset field/control. Avoid
  stacking multiple opaque fills, dark scrims, or unrelated blurs.

## Motion

- Motion explains state or gives tactile feedback; it does not run continuously
  just to make an empty screen feel busy.
- Use `SiphonAnimation.hoverSpring` for pointer feedback,
  `SiphonAnimation.bouncySpring` for press feedback, and
  `SiphonAnimation.fluidSpring` for content/state changes.
- Use `.animation(_:value:)` with a narrow, explicit value and keep animation
  close to the view that changes.
- Respect Reduce Motion. Ambient animation pauses when the app is inactive, and
  the status blob remains subtle behind the progress ring and count.
- Avoid animating layout at the root of a large screen or combining several
  competing spring timings for one interaction.
- Custom frame-scheduled animation uses a 60 Hz baseline and may step up to
  120 Hz when the window is on a display that supports at least 120 Hz.
- Refresh rate changes rendering cadence, not animation physics. Do not shorten
  spring response/damping or otherwise make interactions run faster on
  high-refresh displays.
- Active interaction animation must not be intentionally capped at 30 fps.
  Ambient branding should remain static when idle rather than consuming a
  continuous timeline merely to appear alive.

## Interaction and accessibility

- Use `Button`, `Toggle`, `Picker`, `TextField`, and other native controls for
  actionable UI. A visual card can be a button, but a decorative surface must
  not pretend to be one.
- Every icon-only control needs a concise accessibility label and a help tooltip
  where appropriate.
- Keep accessibility labels action-oriented and do not expose decorative liquid
  effects as elements.
- Preserve keyboard focus, menu/toolbar paths, and sensible disabled states.
- Custom chrome follows the key window's active/inactive appearance through
  `appearsActive`; inactive emphasis should become quieter, not disappear.
- Honor macOS Show Borders for custom interactive surfaces and Reduce
  Transparency for custom material backgrounds.
- Do not show an affordance for an action that cannot currently succeed.

## Liquid Glass policy

1. Start with native macOS materials, controls, toolbars, and sidebar behavior.
2. Use custom glass only for app-specific surfaces such as the URL hero card or
   status controls, where it supports the Siphon identity.
3. Keep related custom glass elements in one visual group so their depth and
   refraction feel coherent.
4. Use tint only for semantic emphasis or a primary action.
5. Every custom glass surface needs a legible Reduce Transparency fallback.
6. Never let blur, refraction, glow, or motion reduce text contrast or obscure
   progress/error state.

## Review checklist

Before merging a UI change, verify:

- [ ] Existing `SiphonTheme`, `SiphonAnimation`, and semantic font roles were
      reused.
- [ ] Light, Dark, inactive-window, and Reduce Transparency states remain
      legible.
- [ ] The interaction works with pointer, keyboard, and VoiceOver.
- [ ] Motion is scoped, purposeful, Reduce Motion-aware, and follows the
      60/120 Hz cadence policy without refresh-dependent physics.
- [ ] Ordinary UI remains SDR; elevated dynamic range is reserved for genuine
      HDR media.
- [ ] P3-owned colors, inactive-window state, Show Borders, and Reduce
      Transparency behavior were preserved.
- [ ] No new hardcoded palette, spacing, radius, blur, or spring values were
      added without a documented reason.
- [ ] Native macOS structure was preferred before custom glass or AppKit code.
- [ ] The affected flow was visually checked at compact and normal window sizes.
