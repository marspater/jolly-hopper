# Sentinel Journal - Security Learnings

## 2026-08-19 - Restrict Extracted Binary Executable Permissions to Owner
**Vulnerability:** Extracted executable binaries (such as `yt-dlp`, `ffmpeg`, and `ffprobe`) staged in Application Support were configured with `0o755` permissions, granting group and world read and execute permissions unnecessarily.
**Learning:** Setting `0o755` permissions on application binaries in user directory locations allows other local non-root user accounts on multi-user systems to read/execute staged binaries if parent folder POSIX attributes are ever broadened.
**Prevention:** Always restrict extracted or downloaded binary permissions to user-only (`0o700`) on macOS/POSIX systems to enforce user isolation boundaries.

## 2026-03-29 - Environment Variable Command Injection in Shell Script Invocation
**Vulnerability:** Passing shell script parameter paths/variables directly via `process.environment` when running `/bin/bash -c` allows potential injection or manipulation if variables are unquoted or evaluated insecurely in shell subshells/traps.
**Learning:** Shell script parameters should be explicitly passed as positional CLI arguments to `/bin/bash` (e.g. `["-c", script, "siphon-update", arg1, arg2]`) and bound via `$1`, `$2`, etc. rather than depending on process environment overrides.
**Prevention:** Avoid passing dynamic paths or parameters in `process.environment` for script execution; always pass them as positional arguments after `-c script <script_name>`.

## 2026-03-30 - AppleScript Code Injection via String Interpolation in osascript
**Vulnerability:** Dynamic strings interpolated directly into AppleScript code blocks executed via `osascript -e` can lead to AppleScript code injection or syntax errors when strings contain quotes, backslashes, or control characters.
**Learning:** Interpolating user or dynamic inputs directly into AppleScript script strings bypasses string parsing boundaries. Passing arguments as positional CLI arguments to `osascript` with `on run argv` allows AppleScript to safely read inputs from `argv` as data values without code evaluation.
**Prevention:** Never interpolate dynamic variables into AppleScript script strings. Always pass parameters as positional arguments to `osascript` using `-e "on run argv"` and reference them via `item 1 of argv`, `item 2 of argv`, etc.

## 2026-04-01 - Missing Sensitive Query Parameters in Log Export Sanitization
**Vulnerability:** `LoggerService.exportSecretQueryRegex` only sanitized a subset of query parameters (`token`, `key`, `password`, etc.), allowing other sensitive parameters like `access_token`, `session`, `jwt`, `oauth_token`, and `client_secret` to leak in plain text when exporting debug logs.
**Learning:** In-line diagnostic logging sanitization (`sanitizeDiagnosticText`) and log export sanitization (`sanitizeLogContentForExport`) must stay synchronized regarding sensitive query parameter keys.
**Prevention:** Keep `exportSecretQueryRegex` aligned with `redactionRegexes` whenever adding new sensitive parameter keys to the logger.

## 2026-03-31 - Unsanitized Host in Netscape Cookie File Generation
**Vulnerability:** Dynamic URL host strings interpolated into Netscape cookie format domain entries were not sanitized for tab, carriage return, and newline control characters, allowing potential cookie line injection in temporary cookie files.
**Learning:** Extracting `URL.host` from user-supplied or deep-link URLs and using it directly in line-oriented file formats (like Netscape HTTP Cookie File syntax) without token sanitization allows control characters (`\t`, `\r`, `\n`) to inject extra Netscape lines.
**Prevention:** Always sanitize `URL.host` and domain strings with `sanitizeCookieToken` (stripping `\t`, `\r`, `\n`, `\0`) before writing them into Netscape cookie files.
