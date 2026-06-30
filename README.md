# Dashboard Frontend

React 19 + Vite + TypeScript frontend for the orders dashboard. Proxies `/api/*` to the Spring Boot backend in dev; served via Nginx in production.

Sister repo: [springboot-gcp-dashboard-backend](https://github.com/bganguly/springboot-gcp-dashboard-backend)

## Local Dev

**Step 1 — start the backend first** ([springboot-gcp-dashboard-backend](https://github.com/bganguly/springboot-gcp-dashboard-backend)):

```bash
./scripts/local-dev.sh   # run from the backend repo
```

**Step 2 — start the frontend:**

```bash
npm install && npm run dev
```

Opens http://localhost:3004. Requires Node 18+.

Override the proxy target if the backend is elsewhere: `BACKEND_URL=http://other-host:8080 npm run dev`

## Deploy (GCP Cloud Run)

```bash
./scripts/deploy.sh
```

Detects GCP project, region, and Artifact Registry repo from your local `gcloud` config and prompts to confirm or override each. Defaults the image tag to the current git commit hash. Builds, pushes, and deploys — prints the Cloud Run URL when done.

The `Dockerfile` builds a multi-stage image (Vite build → Nginx).

## Build

```bash
npm run build
```

Output goes to `dist/`. Served by the Nginx config in `nginx.conf.template`.
