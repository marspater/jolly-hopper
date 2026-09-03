# Sentinel Security Learnings

## 2026-03-30 - Temporary Cookie Directory Permissions Isolation
**Vulnerability:** Temporary cookie files were stored directly in the shared temporary directory (`/tmp`), potentially exposing sensitive cookie data to other unprivileged processes on shared systems.
**Learning:** Storing sensitive temp files in the root temporary directory can expose them to local unprivileged processes if directory permissions are overly broad.
**Prevention:** Isolate sensitive temporary files into a dedicated subdirectory created with restricted `0o700` POSIX permissions and strict file creation permissions (`0o600`).
