## 2024-05-24 - Accessibility labels for icon-only buttons
**Learning:** In macOS SwiftUI apps, while `.help()` provides visual tooltips for icon-only buttons, it does not reliably serve as a fallback for VoiceOver, meaning explicit `.accessibilityLabel()` modifiers are required for true accessibility.
**Action:** Always add `.accessibilityLabel()` to icon-only buttons even if they already have a `.help()` modifier.
