# Siphon Companion Service

A lightweight, zero-dependency Node.js companion service designed for Render preview deployments and autonomous Jules repair workflows.

## Render Configuration

When setting up this service on Render:

- **Root Directory**: `server`
- **Language**: `Node`
- **Build Command**: `npm install` (or `npm test`)
- **Start Command**: `npm start`
- **Health Check Path**: `/health`

## Endpoints

- `GET /`: Returns service status and timestamp.
- `GET /health`: Health check endpoint for Render.
