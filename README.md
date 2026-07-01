# Dashboard Frontend — React 19 + TypeScript + GCP Cloud Run

Production-grade **React 19 / TypeScript** SPA for the orders dashboard, delivering sub-second
search and chart responses across 4 million orders. Served via multi-stage Docker build (Vite → Nginx),
deployed as a GCP Cloud Run service managed by **Pulumi TypeScript IaC**. Nginx acts as a BFF proxy —
routing `/api/*` to the Spring Boot backend with TLS SNI passthrough.

Sister repo: [springboot-gcp-dashboard-backend](https://github.com/bganguly/springboot-gcp-dashboard-backend)

> **Infrastructure note:** all GCP resources — including this Cloud Run service — are declared in
> `springboot-gcp-dashboard-backend/infra/index.ts` (Pulumi). The frontend `deploy.sh` sets
> `pulumi config set frontendImage` then delegates to `pulumi up --yes` in that directory.

---

## CVS JD Alignment

| JD Requirement | This Project |
|---|---|
| **React / TypeScript front-end** | React 19, TypeScript, Vite, Tailwind CSS, Recharts |
| **BFF layer** | Nginx reverse proxy: `/api/*` → Spring Boot (TLS + `proxy_ssl_server_name on` for Cloud Run SNI) |
| **Serverless / cloud-native** | Cloud Run — 0–3 instances, scales to zero, no node management |
| **IaC (Terraform equivalent)** | Pulumi TypeScript in `../springboot-gcp-dashboard-backend/infra/` — frontend Cloud Run service, IAM, and `BACKEND_URL` env all declared |
| **CI/CD pipelines** | `deploy.sh` — multi-stage Docker build → push to Artifact Registry → `pulumi up --yes` |
| **Performance optimization** | Sub-second chart responses from pre-aggregated GCP Cloud SQL tables (< 1 s); sub-second list search via GIN trigram index on denormalized `search_text` column |
| **System design diagrams** | See [backend README](https://github.com/bganguly/springboot-gcp-dashboard-backend) for full topology |

---

## Tech Stack

**Frontend:** React 19, TypeScript, Vite, Tailwind CSS, Recharts  
**Server:** Nginx (BFF proxy + static file server)  
**Cloud:** GCP Cloud Run (serverless, 0–3 instances), Artifact Registry  
**IaC:** Pulumi TypeScript (managed from `springboot-gcp-dashboard-backend/infra/`)  
**Build:** Multi-stage Dockerfile — `node:22-alpine` (Vite build) → `nginx:alpine`

---

## Features

- **Orders table** — paginated, sortable (date / total / status), filter sidebar (status, region, date range, total range)
- **Full-text search** — multi-token AND search across all visible columns (name, notes, total, order ID, status, region, date) via backend `search_text` GIN trigram index; sub-second responses on 4 M rows
- **Aggregates chart** — stacked bar chart of daily orders by product category; Recharts brush for date range zoom; sub-second responses from pre-aggregated tables, never queries raw orders
- **Dark mode** — system-preference detection via `useIsDark` hook
- **BFF proxy** — Nginx forwards `/api/*` to Spring Boot with `proxy_ssl_server_name on`; browser sees a single origin, no CORS

---

## Scale & Performance

> **4 M+ orders** served with sub-second search and chart responses. Full-text search hits a single GIN trigram index on `search_text`; chart aggregates hit pre-aggregated summary tables — neither touches the raw `orders` table on the hot path.

```
Browser ──HTTPS──► Nginx / Cloud Run ──proxy /api/* (SNI)──► Spring Boot / Cloud Run ──VPC──► Cloud SQL PG 16
                   dash-frontend (this repo)                 dash-backend                      4 M+ rows
                   0–3 instances                             1–5 instances                     GIN trigram index
```

---

## Local Dev

**Step 1** — start the backend first (from [springboot-gcp-dashboard-backend](https://github.com/bganguly/springboot-gcp-dashboard-backend)):

```bash
./scripts/local-dev.sh
```

**Step 2** — start the frontend:

```bash
npm install && npm run dev
```

Opens http://localhost:3004. Node 18+ required.

Override the proxy target if the backend runs elsewhere:

```bash
BACKEND_URL=http://other-host:8080 npm run dev
```

---

## Deploy (GCP Cloud Run via Pulumi)

```bash
./scripts/deploy.sh
```

1. Reads GCP project and region from `gcloud` config (falls back to `.env.gcp` in the backend repo)
2. Builds and tags the Docker image (`<region>-docker.pkg.dev/<project>/dash-repo/frontend:<git-sha>`)
3. Pushes to GCP Artifact Registry
4. Runs `pulumi config set frontendImage <image>` in `springboot-gcp-dashboard-backend/infra/`
5. Runs `pulumi up --yes` — creates or updates the `dash-frontend` Cloud Run service
6. Prints the `frontendUrl` Pulumi stack output

All infra state is tracked in the Pulumi stack — no manual `gcloud run deploy` commands.

---

## Live Service

| | URL |
|---|---|
| **Frontend** | https://dash-frontend-7u2hpcwtmq-uc.a.run.app |
| **Backend API** | https://dash-backend-7u2hpcwtmq-uc.a.run.app |

### Quick test — local (via Vite dev-server proxy)

```bash
curl "http://localhost:3004/api/orders?page=1&size=3" | jq .total
curl "http://localhost:3004/api/orders?q=ava+ito&page=1&size=3" | jq '.data[].customer'
curl "http://localhost:3004/api/aggregates?from=2024-01-01&to=2024-12-31" | jq 'length'
```

### Quick test — deployed (via Nginx proxy)

```bash
BASE=https://dash-frontend-7u2hpcwtmq-uc.a.run.app
curl -I "$BASE"                                                    # React SPA — expect 200 text/html
curl "$BASE/api/orders?page=1&size=3" | jq .total                 # proxied to Spring Boot
curl "$BASE/api/orders?q=ava+ito&page=1&size=3" | jq '.data[].customer'
curl "$BASE/api/aggregates?from=2024-01-01&to=2024-12-31" | jq 'length'
```

---

## Tear Down

> **FYI:** The frontend Cloud Run service scales to zero — no idle compute cost. However, Cloud SQL, the VPC connector, and the backend Cloud Run service (min 1 instance) all bill continuously. Full teardown must be run from the backend repo.

All resources are destroyed from the backend repo:

```bash
GCP_PROJECT=your-project-id ./scripts/infra-down.sh   # from springboot-gcp-dashboard-backend
```

This runs `pulumi destroy --yes` which removes both the frontend and backend Cloud Run services,
Cloud SQL, VPC, Secret Manager secrets, Artifact Registry, and all IAM bindings.

---

## Architecture / Topology

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              GCP Project                                │
│                                                                         │
│   Artifact Registry                                                     │
│   ┌──────────────────┐    ◄── docker push (deploy.sh)                  │
│   │  frontend image  │                                                  │
│   │  backend image   │                                                  │
│   └──────────────────┘                                                  │
│           │ image pull                                                  │
│           ▼                                                             │
│   ┌───────────────────────────────────────────────────────────────┐     │
│   │                       dash-vpc (private)                      │     │
│   │                                                               │     │
│   │  Cloud Run: dash-frontend          Cloud Run: dash-backend    │     │
│   │  ┌─────────────────────────┐       ┌──────────────────────┐   │     │
│   │  │ Nginx (port 80)         │       │ Spring Boot (8080)   │   │     │
│   │  │ • serves Vite dist      │ HTTPS │ • REST /api/*        │   │     │
│   │  │ • proxies /api/* ───────┼──────►│ • Flyway migrations  │   │     │
│   │  │   proxy_ssl_server_name │  SNI  │ • 1–5 instances      │   │     │
│   │  │ • 0–3 instances         │       └──────────┬───────────┘   │     │
│   │  └─────────────────────────┘                  │               │     │
│   │           ▲                          Direct VPC Egress        │     │
│   └───────────┼──────────────────────────────────┼───────────────┘     │
│               │ HTTPS                             │ private IP           │
│           Browser                    ┌────────────▼───────────┐        │
│                                      │  Cloud SQL PG 16       │        │
│                                      │  4 M orders            │        │
│                                      │  GIN trigram index     │        │
│                                      │  pre-agg summary tables│        │
│                                      └────────────────────────┘        │
│                                                                         │
│   Pulumi TypeScript (infra/index.ts) manages all resources above        │
│   Secret Manager: dash-database-url (injected into backend at runtime)  │
└─────────────────────────────────────────────────────────────────────────┘
```
