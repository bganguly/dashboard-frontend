#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
BACKEND_INFRA_DIR="$(cd "$ROOT_DIR/../springboot-gcp-dashboard-backend/infra" && pwd)"
ENV_FILE="$ROOT_DIR/../springboot-gcp-dashboard-backend/.env.gcp"
cd "$ROOT_DIR"

# One-shot by default — every value below is auto-detected/derived with no
# confirmation prompt, matching the nextjs repos' deploy.sh scripts. The only
# interactive stops left are genuine forks in the road: gcloud/ADC login (no
# headless alternative exists) and an unhealthy backend (a real reason to
# reconsider before proceeding, not a safe default).

# ── gcloud install ────────────────────────────────────────────────────────────
if ! command -v gcloud >/dev/null 2>&1; then
  printf '\ngcloud CLI not found.\n'
  if command -v brew >/dev/null 2>&1; then
    printf 'Installing via Homebrew...\n'
    brew install --cask google-cloud-sdk
    # shellcheck source=/dev/null
    source "$(brew --prefix)/share/google-cloud-sdk/path.bash.inc" 2>/dev/null || true
  else
    printf 'Install it from: https://cloud.google.com/sdk/docs/install\nThen re-run this script.\n'
    exit 1
  fi
fi

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
if [[ -z "$ACTIVE_ACCOUNT" ]]; then
  printf '\nNot authenticated — logging in...\n'
  gcloud auth login
  ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
  [[ -n "$ACTIVE_ACCOUNT" ]] || { printf 'Login did not complete.\n' >&2; exit 1; }
fi
printf '\nAuthenticated as: %s\n' "$ACTIVE_ACCOUNT"

# ── seed known values ─────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# ── config ────────────────────────────────────────────────────────────────────
printf '\n=== deployment config ===\n'

_CONFIG_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
GCP_PROJECT="${_CONFIG_PROJECT:-${GCP_PROJECT:-}}"
[[ -n "$GCP_PROJECT" ]] || { printf '\nNo GCP project detected. Run: gcloud config set project <id>\n' >&2; exit 1; }

_CONFIG_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
GCP_REGION="${_CONFIG_REGION:-${GCP_REGION:-us-central1}}"

_GIT_HASH=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)
_BUILD_TS=$(date +%Y%m%d%H%M%S)
TAG="${_GIT_HASH:+${_GIT_HASH}-}${_BUILD_TS}"

printf '  Project: %s\n  Region:  %s\n' "$GCP_PROJECT" "$GCP_REGION"

# ── backend health check ──────────────────────────────────────────────────────
BACKEND_URL=""
if [[ -d "$BACKEND_INFRA_DIR" ]] && command -v pulumi >/dev/null 2>&1; then
  BACKEND_URL=$(cd "$BACKEND_INFRA_DIR" && \
    pulumi stack output backendUrl 2>/dev/null || true)
fi
[[ -n "$BACKEND_URL" ]] || { printf '\nCould not read backendUrl from Pulumi stack — run the backend deploy first.\n' >&2; exit 1; }

printf '\n  Checking backend health at %s ...\n' "$BACKEND_URL"
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  "${BACKEND_URL}/api/customers" --max-time 10 2>/dev/null || echo "000")
if [[ "$HTTP_STATUS" == "200" ]]; then
  printf '  Backend is healthy (HTTP 200).\n'
elif [[ "$HTTP_STATUS" == "000" ]]; then
  printf '  WARNING: Backend did not respond. Deploy anyway? [y/N] '
  read -r proceed
  [[ "$proceed" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }
else
  printf '  WARNING: Backend returned HTTP %s. Deploy anyway? [y/N] ' "$HTTP_STATUS"
  read -r proceed
  [[ "$proceed" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }
fi

# ── Artifact Registry ─────────────────────────────────────────────────────────
_LISTED_REGISTRY=$(gcloud artifacts repositories list \
  --project="$GCP_PROJECT" \
  --location="$GCP_REGION" \
  --format="value(name)" 2>/dev/null | head -1 || true)
_LISTED_REGISTRY="${_LISTED_REGISTRY##*/}"
REGISTRY="${_LISTED_REGISTRY:-${ARTIFACT_REGISTRY:-${GCP_PROJECT}-gradle}}"

if ! gcloud artifacts repositories describe "$REGISTRY" \
      --project="$GCP_PROJECT" --location="$GCP_REGION" >/dev/null 2>&1; then
  printf '\n  No Artifact Registry repo found — creating "%s" in %s...\n' "$REGISTRY" "$GCP_REGION"
  gcloud artifacts repositories create "$REGISTRY" \
    --repository-format=docker \
    --location="$GCP_REGION" \
    --project="$GCP_PROJECT"
fi

IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REGISTRY}/frontend:${TAG}"
printf '\nBuilding and pushing:\n  %s\n' "$IMAGE"
printf 'Then deploying via Pulumi (backend infra stack).\n'

# ── build & push ──────────────────────────────────────────────────────────────
if docker info >/dev/null 2>&1; then
  printf '\n[1/3] configuring docker auth...\n'
  gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet
  printf '[2/3] building image...\n'
  docker build --platform linux/amd64 -t "$IMAGE" "$ROOT_DIR"
  printf '[3/3] pushing image...\n'
  docker push "$IMAGE"
else
  printf '\nDocker not available — building via Cloud Build...\n'
  gcloud services enable cloudbuild.googleapis.com --project "$GCP_PROJECT"
  gcloud builds submit --tag "$IMAGE" --project "$GCP_PROJECT" "$ROOT_DIR"
fi

# ── application default credentials (required by Pulumi GCP provider) ─────────
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf '\nSetting up Application Default Credentials (required by Pulumi)...\n'
  gcloud auth application-default login
fi

# ── deploy via pulumi ─────────────────────────────────────────────────────────
printf '\n=== deploying via Pulumi ===\n'

cd "$INFRA_DIR"
npm install --prefer-offline 2>/dev/null || npm install
pulumi stack select "dev" 2>/dev/null || pulumi stack init "dev"
pulumi config set gcp:project    "$GCP_PROJECT"
pulumi config set gcp:region     "$GCP_REGION"
pulumi config set backendUrl     "$BACKEND_URL"
pulumi config set frontendImage  "$IMAGE"
pulumi up --yes

FRONTEND_URL=$(pulumi stack output frontendUrl 2>/dev/null || true)
printf '\nDone. Frontend URL:\n  %s\n' "$FRONTEND_URL"
