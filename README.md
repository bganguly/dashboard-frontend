# Dashboard Frontend

React 19 + Vite + TypeScript frontend for the orders dashboard. Proxies `/api/*` to the Spring Boot backend in dev; served via Nginx in production.

Sister repos: [springboot-gcp-dashboard-backend](https://github.com/bganguly/springboot-gcp-dashboard-backend) · [typescript-implementations](https://github.com/bganguly/typescript-implementations) (Next.js variant).

## Local Dev

### Prerequisites

- Node 18+, npm
- [springboot-gcp-dashboard-backend](https://github.com/bganguly/springboot-gcp-dashboard-backend) running on http://localhost:8080

### Start

```bash
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
