## 2024-09-12 - Added CustomPreset Serialization Tests
**Learning:** Testing pure data structures that conform to Codable in Swift requires verifying full serialization, minimal instantiation defaults, and legacy JSON payload mapping (where optional properties are missing).
**Action:** Always create tests that use minimal/legacy string payloads to test robust `nil` fallback mapping for properties that might have been added in later application versions.
