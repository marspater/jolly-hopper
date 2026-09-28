# Siphon Companion Service

A lightweight, zero-dependency Node.js companion service designed for Render preview deployments and autonomous Jules repair workflows.

## Render Configuration

When setting up this service on Render:

- **Root Directory**: `server`
- **Language**: `Node`
- **Build Command**: `npm install`
- **Start Command**: `npm start`
- **Health Check Path**: `/healthz` (or `/health`)

The service listens on `PORT` (default `3000`). On Render (where `RENDER` is set) it binds to all interfaces so Render can route traffic to it; everywhere else it binds to `127.0.0.1`. Set `HOST` to override either.

## Endpoints

### System & Health
- `GET /`: Returns service status and timestamp.
- `GET /health`, `GET /healthz`: Health check endpoints for Render and keep-alive pings.

### Release & Metadata
- `GET /api/latest`: Cached GitHub latest release metadata for Siphon (15-minute in-memory cache to prevent GitHub rate-limiting).

### Test Fixtures
- `GET /mock/subtitles.vtt`: Valid WebVTT subtitle stream for subtitle parser verification.
- `GET /mock/playlist.m3u8`: HLS playlist referencing one 1-second MPEG-TS segment.
- `GET /mock/segment0.ts`: The playlist's H.264/AAC MPEG-TS segment.
- `GET /mock/video.mp4`: 1-second 16x16 H.264/AAC MP4 that decodes with FFmpeg.

Fixture binaries live in `fixtures/`.
