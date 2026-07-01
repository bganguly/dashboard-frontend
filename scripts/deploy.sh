#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_INFRA_DIR="$(cd "$ROOT_DIR/../springboot-gcp-dashboard-backend/infra" && pwd)"
ENV_FILE="$ROOT_DIR/../springboot-gcp-dashboard-backend/.env.gcp"
cd "$ROOT_DIR"

# ── helpers ───────────────────────────────────────────────────────────────────
ask() {
  local label="$1" hint="$2" default="$3"
  printf '\n  %s\n' "$label" >&2
  [[ -n "$hint"    ]] && printf '  → %s\n' "$hint" >&2
  [[ -n "$default" ]] && printf '  [detected: %s]\n' "$default" >&2
  printf '  > ' >&2
  read -r input
  echo "${input:-$default}"
}

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
  printf '\nNot authenticated. Log in now? [Y/n] '
  read -r do_login
  if [[ -z "$do_login" || "$do_login" =~ ^[Yy]$ ]]; then
    gcloud auth login
    ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
    [[ -n "$ACTIVE_ACCOUNT" ]] || { printf 'Login did not complete.\n' >&2; exit 1; }
  else
    printf 'Exiting.\n'; exit 1
  fi
fi
printf '\nAuthenticated as: %s\n' "$ACTIVE_ACCOUNT"

# ── seed known values ─────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# ── config ────────────────────────────────────────────────────────────────────
printf '\n=== deployment config ===\n'

DETECTED_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
DETECTED_PROJECT="${DETECTED_PROJECT:-${GCP_PROJECT:-}}"
DETECTED_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
DETECTED_REGION="${DETECTED_REGION:-${GCP_REGION:-us-central1}}"
_GIT_HASH=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)
_BUILD_TS=$(date +%Y%m%d%H%M%S)
DETECTED_TAG="${_GIT_HASH:+${_GIT_HASH}-}${_BUILD_TS}"

GCP_PROJECT=$(ask "GCP project ID" \
  "gcloud projects list" "$DETECTED_PROJECT")
[[ -n "$GCP_PROJECT" ]] || { printf '\nProject ID required.\n' >&2; exit 1; }

GCP_REGION=$(ask "Region" \
  "Common: us-central1, us-east1" "$DETECTED_REGION")

# ── backend health check ──────────────────────────────────────────────────────
DETECTED_BACKEND_URL=""
if [[ -d "$BACKEND_INFRA_DIR" ]] && command -v pulumi >/dev/null 2>&1; then
  DETECTED_BACKEND_URL=$(cd "$BACKEND_INFRA_DIR" && \
    pulumi stack output backendUrl 2>/dev/null || true)
fi
[[ -n "$DETECTED_BACKEND_URL" ]] || { printf '\nCould not read backendUrl from Pulumi stack — run the backend deploy first.\n' >&2; exit 1; }

printf '\n  Checking backend health at %s ...\n' "$DETECTED_BACKEND_URL"
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  "${DETECTED_BACKEND_URL}/api/customers" --max-time 10 2>/dev/null || echo "000")
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
DETECTED_REGISTRY=$(gcloud artifacts repositories list \
  --project="$GCP_PROJECT" \
  --location="$GCP_REGION" \
  --format="value(name)" 2>/dev/null | head -1 || true)
DETECTED_REGISTRY="${DETECTED_REGISTRY##*/}"

REGISTRY=$(ask "Artifact Registry repo name" \
  "gcloud artifacts repositories list --project=${GCP_PROJECT} --location=${GCP_REGION}" \
  "$DETECTED_REGISTRY")
[[ -n "$REGISTRY" ]] || { printf '\nRegistry required.\n' >&2; exit 1; }

TAG=$(ask "Image tag" "leave blank for git-hash+timestamp" "$DETECTED_TAG")
IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REGISTRY}/frontend:${TAG}"

# ── confirm ───────────────────────────────────────────────────────────────────
printf '\nWill build and push:\n  %s\n' "$IMAGE"
printf 'Then deploy via Pulumi (backend infra stack).\n'
printf '\nProceed? [Y/n] '
read -r yn
[[ -z "$yn" || "$yn" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

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
  printf '\nApplication Default Credentials needed for Pulumi. Set up now? [Y/n] '
  read -r do_adc
  if [[ -z "$do_adc" || "$do_adc" =~ ^[Yy]$ ]]; then
    gcloud auth application-default login
  else
    printf 'Run: gcloud auth application-default login\n'; exit 1
  fi
fi

# ── deploy via pulumi ─────────────────────────────────────────────────────────
printf '\n=== deploying via Pulumi ===\n'
cd "$BACKEND_INFRA_DIR"
npm install --prefer-offline 2>/dev/null || npm install
pulumi stack select "dev" 2>/dev/null || pulumi stack init "dev"
pulumi config set gcp:project "$GCP_PROJECT"
pulumi config set gcp:region  "$GCP_REGION"
pulumi config set frontendImage "$IMAGE"
pulumi up --yes

FRONTEND_URL=$(pulumi stack output frontendUrl 2>/dev/null || true)
printf '\nDone. Frontend URL:\n  %s\n' "$FRONTEND_URL"
