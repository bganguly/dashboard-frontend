# Dashboard Frontend

React 19 + Vite + TypeScript frontend for the orders dashboard. Proxies `/api/*` to the Spring Boot backend in dev; served via Nginx in production.

Sister repo: [springboot-gcp-dashboard-backend](https://github.com/bganguly/springboot-gcp-dashboard-backend)

## Local Dev

### Prerequisites

- Node 18+, npm
- Backend running on http://localhost:8080 — see [springboot-gcp-dashboard-backend](https://github.com/bganguly/springboot-gcp-dashboard-backend) Quick Start

### Quick Start (first time)

```bash
# 1. Check Node version (need 18+)
node --version

# 2. Install and start
npm install
npm run dev
```

Opens http://localhost:3004. Vite proxies `/api/*` to `http://localhost:8080` automatically.

Set `BACKEND_URL` to override the proxy target:

```bash
BACKEND_URL=http://other-host:8080 npm run dev
```

## Build

```bash
npm run build
```

Output goes to `dist/`. Served by the Nginx config in `nginx.conf.template`.

## Deploy (GCP Cloud Run)

The `Dockerfile` builds a multi-stage image (Vite build → Nginx). Deploy alongside the backend:

```bash
# build and push
IMAGE=us-central1-docker.pkg.dev/<project>/<registry>/frontend:<tag>
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"
gcloud run deploy dashboard-frontend --image "$IMAGE" --region us-central1
```
