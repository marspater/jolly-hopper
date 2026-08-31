## 2024-05-24 - Accessibility labels for icon-only buttons
**Learning:** In macOS SwiftUI apps, while `.help()` provides visual tooltips for icon-only buttons, it does not reliably serve as a fallback for VoiceOver, meaning explicit `.accessibilityLabel()` modifiers are required for true accessibility.
**Action:** Always add `.accessibilityLabel()` to icon-only buttons even if they already have a `.help()` modifier.

## 2026-08-31 - Secondary Window Environment Injection
**Learning:** Adding an `@EnvironmentObject` (like `LanguageService`) to a SwiftUI view that serves as the root of a secondary window (like `DebugLogView` via `DebugLogWindowManager`) will cause a fatal runtime crash if not properly injected at the creation site.
**Action:** When adding accessibility labels to views managed by separate window coordinators, verify environment injection safety. If unsafe, use hardcoded strings (especially acceptable for debug/internal views) instead of risking crashes.
