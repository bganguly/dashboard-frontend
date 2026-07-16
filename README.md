# Dashboard Frontend — React 19 + TypeScript + GCP Cloud Run

Production-grade **React 19 / TypeScript** SPA for the orders dashboard, delivering sub-second
search and chart responses across 4 million orders. Served via multi-stage Docker build (Vite → Nginx),
deployed as a GCP Cloud Run service managed by **Pulumi TypeScript IaC**. Nginx acts as a BFF proxy —
routing `/api/*` to the Spring Boot backend with TLS SNI passthrough.

**[→ Portfolio demo](https://bganguly.github.io/?open=dashboard)**

## Using the App

1. **Search** — type in the search bar to query across all columns (name, notes, total, order ID, status, region, date) via GIN trigram index; sub-second on 4 M+ rows.
2. **Filter** — use the sidebar to narrow by status, region, date range, or total amount.
3. **Aggregates chart** — the chart shows daily orders by product category; drag the brush to zoom into any date window.

---

| | |
|---|---|
| **React / TypeScript front-end** | React 19, TypeScript, Vite, Tailwind CSS, Recharts |
| **BFF layer** | Nginx reverse proxy: `/api/*` → Spring Boot (TLS + `proxy_ssl_server_name on` for Cloud Run SNI) |
| **Serverless / cloud-native** | Cloud Run — 0–3 instances, scales to zero, no node management |
| **IaC (Terraform equivalent)** | Pulumi TypeScript in `../springboot-gcp-dashboard-backend/infra/` — frontend Cloud Run service, IAM, and `BACKEND_URL` env all declared |
| **CI/CD pipelines** | `deploy.sh` — multi-stage Docker build → push to Artifact Registry → `pulumi up --yes` |
| **Performance optimization** | Sub-second chart responses from pre-aggregated GCP Cloud SQL tables (< 1 s); sub-second list search via GIN trigram index on denormalized `search_text` column |
| **System design diagrams** | See [backend README](https://github.com/bganguly/springboot-gcp-dashboard-backend) for full topology |

---

## Features

- **Orders table** — paginated, sortable (ID / customer / total / date), filter sidebar (status, region, date range, total range)
- **Full-text search** — multi-token AND search across all visible columns (name, notes, total, order ID, status, region, date) via backend `search_text` GIN trigram index; sub-second responses on 4 M rows
- **Aggregates chart** — stacked bar chart of daily orders by product category; sub-second responses from pre-aggregated tables, never queries raw orders
- **Date brush** — Recharts brush control on the aggregates chart; drag to zoom into any date window, releases back to the selected date range
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

## Running

Both scripts prompt for **[1] Local** or **[2] Remote (GCP)** on launch.

| Action | Script | Prompt | Notes |
|---|---|---|---|
| Start local dev server | `./scripts/deploy.sh` | `[1]` | Start backend first (`springboot-dashboard-backend-gcp`) |
| Deploy to GCP (Cloud Run or GKE) | `./scripts/deploy.sh` | `[2]` | Backend must be deployed first |
| Stop local dev server | `./scripts/infra-down.sh` | `[1]` | Kills port 3006 |
| Teardown GCP frontend | `./scripts/infra-down.sh` | `[2]` | Pulumi destroy on frontend stack |

`./scripts/deploy.sh [2]` builds the Docker image (Vite → Nginx multi-stage), pushes to Artifact Registry, and runs `pulumi up --yes` to deploy the frontend Cloud Run service:

```
./scripts/deploy.sh [2]
  ├─ docker build (multi-stage: Vite build → Nginx image)
  ├─ docker push → Artifact Registry
  └─ pulumi up --yes
       └─ Cloud Run: dash-frontend (0–3 instances, BACKEND_URL injected)
```

Local: `BACKEND_URL=http://other-host:8080 ./scripts/deploy.sh` to override the backend target. Node 20+ required.

> **GCP cost:** The frontend Cloud Run service scales to zero — no idle cost. Cloud SQL and backend min-instance in [springboot-dashboard-backend-gcp](https://github.com/bganguly/springboot-dashboard-backend-gcp) bill continuously; run teardown there when not actively demoing.

> **GCP availability:** The live GCP endpoint is not guaranteed to be running at all times. Use local mode to explore without incurring cloud costs.

---

## Live Service

| | URL |
|---|---|
| **Frontend** | https://dash-frontend-7u2hpcwtmq-uc.a.run.app |

```bash
# local (via Vite dev-server proxy)
curl "http://localhost:3006/api/orders?page=1&size=3" | jq .total

# GCP (if deployed, via Nginx proxy)
BASE=https://dash-frontend-7u2hpcwtmq-uc.a.run.app
curl -I "$BASE"
curl "$BASE/api/orders?page=1&size=3" | jq .total
```

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
