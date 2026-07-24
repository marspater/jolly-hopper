## 2024-05-24 - Accessibility Labels for Icon-Only Buttons
**Learning:** In macOS SwiftUI apps, while `.help()` provides visual tooltips for icon-only buttons, it does not reliably serve as a fallback for VoiceOver. Explicit `.accessibilityLabel()` modifiers are always required for true accessibility on icon-only buttons.
**Action:** Always add `.accessibilityLabel()` to icon-only buttons in addition to `.help()` modifiers.
