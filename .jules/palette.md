## 2024-05-24 - Accessibility labels for icon-only buttons
**Learning:** In macOS SwiftUI apps, while `.help()` provides visual tooltips for icon-only buttons, it does not reliably serve as a fallback for VoiceOver, meaning explicit `.accessibilityLabel()` modifiers are required for true accessibility.
**Action:** Always add `.accessibilityLabel()` to icon-only buttons even if they already have a `.help()` modifier.

## 2024-11-20 - [SwiftUI View Modifier Analysis]
**Learning:** In SwiftUI, view modifiers (like `.help` and `.accessibilityLabel`) frequently span multiple consecutive lines. When analyzing the codebase for missing UI modifiers, avoid single-line text filtering (`grep -v`), as it will yield false positives. Use multiline processing or Python scripts (e.g., `readlines()`) for accurate contextual code analysis.
**Action:** Next time I need to find missing view modifiers, write a quick python script to parse the lines sequentially rather than relying on standard bash text searching tools.
