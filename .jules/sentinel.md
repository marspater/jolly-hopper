# Sentinel Journal - Security Learnings

## 2026-08-19 - Restrict Extracted Binary Executable Permissions to Owner
**Vulnerability:** Extracted executable binaries (such as `yt-dlp`, `ffmpeg`, and `ffprobe`) staged in Application Support were configured with `0o755` permissions, granting group and world read and execute permissions unnecessarily.
**Learning:** Setting `0o755` permissions on application binaries in user directory locations allows other local non-root user accounts on multi-user systems to read/execute staged binaries if parent folder POSIX attributes are ever broadened.
**Prevention:** Always restrict extracted or downloaded binary permissions to user-only (`0o700`) on macOS/POSIX systems to enforce user isolation boundaries.

## 2026-03-29 - Environment Variable Command Injection in Shell Script Invocation
**Vulnerability:** Passing shell script parameter paths/variables directly via `process.environment` when running `/bin/bash -c` allows potential injection or manipulation if variables are unquoted or evaluated insecurely in shell subshells/traps.
**Learning:** Shell script parameters should be explicitly passed as positional CLI arguments to `/bin/bash` (e.g. `["-c", script, "siphon-update", arg1, arg2]`) and bound via `$1`, `$2`, etc. rather than depending on process environment overrides.
**Prevention:** Avoid passing dynamic paths or parameters in `process.environment` for script execution; always pass them as positional arguments after `-c script <script_name>`.
