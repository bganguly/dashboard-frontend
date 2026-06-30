# Dashboard Frontend

React 19 + Vite + TypeScript frontend for the orders dashboard. Proxies `/api/*` to the Spring Boot backend in dev; served via Nginx in production.

Sister repo: [springboot-gcp-dashboard-backend](https://github.com/bganguly/springboot-gcp-dashboard-backend)

## Local Dev

```bash
node --version   # must be 18+
npm install
npm run dev
```

Opens http://localhost:3004. Vite proxies `/api/*` to `http://localhost:8080` automatically.

**Prerequisites:** backend running on http://localhost:8080 — see [springboot-gcp-dashboard-backend](https://github.com/bganguly/springboot-gcp-dashboard-backend) (`./scripts/local-dev.sh`).

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
IMAGE=us-central1-docker.pkg.dev/<project>/<registry>/frontend:<tag>
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"
gcloud run deploy dashboard-frontend --image "$IMAGE" --region us-central1
```
