# Jules Agent Instructions

These instructions apply to **Jules only**. Follow the shared repository contract in the root `AGENTS.md` as well.

## Execution mode

Jules is an autonomous, headless, disposable runner. The environment is assumed disposable **only because Jules explicitly provides that execution mode**; never generalize these rules to Antigravity or a user's local workspace.

## Destructive bootstrap

At the start of a Jules session, synchronize and reset to the current remote baseline:

```bash
git fetch origin main --prune
git checkout -B main origin/main
git reset --hard origin/main
git clean -fdx
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
```

These destructive commands are authorized **only inside the disposable Jules environment**. Never copy this bootstrap into Antigravity/local-workspace instructions.

Do not preserve stale work from previous Jules sessions unless the task explicitly requires an existing branch/worktree.

## Task loop

1. Read the root contract and this file.
2. Read only the relevant specialist file: Palette for UI/UX/accessibility, Bolt for performance, Sentinel for security, Testing for test-specific guidance.
3. Inspect current `origin/main`, relevant code, recent commits, and existing implementations before changing anything.
4. Make one focused change with the smallest correct diff; do not manufacture work.
5. Re-check `origin/main` before major implementation decisions and before finalizing.
6. Run relevant Xcode build/tests and report results honestly.
7. Create a focused PR only when the task is implemented and verified.

## Specialist boundaries

Do not mix unrelated specialist scopes into one PR. Specialist journals are not work logs and should be updated only when a reusable, application-specific learning is discovered.

## PR expectations

PR titles and descriptions should be concise, factual, and limited to the implemented task. Include what changed, why, validation performed, and relevant limitations. Add screenshots for visually meaningful UI changes when practical.

## Issue tracker & Linear context

Project tasks and issues are tracked on **Linear**.
- Reference the Linear issue identifier (e.g., `fixes ENG-123` or reference the ticket) in PR descriptions when applicable.
- Keep PR descriptions factual and aligned with the Linear ticket scope.

## Render integration & companion service

The project runs an isolated companion web service on **Render** (`https://jolly-hopper.onrender.com`) sourced from `server/`.
- **Preview Deployments & Self-Healing:** Render automatically runs preview deployments for PRs and is connected to Jules. If a preview build fails, Render sends build logs to Jules to diagnose and commit fixes to the PR branch.
- **Strict Isolation:** Keep `server/` self-contained. Never move `package.json` or web dependencies to the repository root; the root must remain a pure native Swift macOS project.
- **Deterministic Test Fixtures:** For tests requiring network/media streaming without hitting live rate-limited video platforms:
  - WebVTT subtitles: `https://jolly-hopper.onrender.com/mock/subtitles.vtt`
  - HLS playlist: `https://jolly-hopper.onrender.com/mock/playlist.m3u8`
  - MP4 video: `https://jolly-hopper.onrender.com/mock/video.mp4`
  - App release metadata: `https://jolly-hopper.onrender.com/api/latest`

## Repository hygiene

Do not leave temporary scripts, debug output, generated artifacts, unrelated changes, merge markers, or stale worktree modifications. Follow the root validation and engineering rules.

**Jules principle:** destructive Git operations are acceptable only because the Jules environment is explicitly disposable; treat every local human workspace as protected unless separately authorized.