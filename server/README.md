# Siphon Companion Service

A lightweight, zero-dependency Node.js companion service designed for Render preview deployments and autonomous Jules repair workflows.

## Render Configuration

When setting up this service on Render:

- **Root Directory**: `server`
- **Language**: `Node`
- **Build Command**: `npm install`
- **Start Command**: `npm start`
- **Health Check Path**: `/healthz` (or `/health`)

## Endpoints

### System & Health
- `GET /`: Returns service status and timestamp.
- `GET /health`, `GET /healthz`: Health check endpoints for Render and keep-alive pings.

### Release & Metadata
- `GET /api/latest`: Cached GitHub latest release metadata for Siphon (15-minute in-memory cache to prevent GitHub rate-limiting).

### Test Fixtures
- `GET /mock/subtitles.vtt`: Valid WebVTT subtitle stream for subtitle parser verification.
- `GET /mock/playlist.m3u8`: Valid HLS streaming playlist manifest.
- `GET /mock/video.mp4`: Minimal valid ISO MP4 binary video stream.
