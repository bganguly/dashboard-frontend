#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ── helpers ───────────────────────────────────────────────────────────────────
ask() {
  local label="$1" hint="$2" default="$3"
  printf '\n  %s\n' "$label"
  [[ -n "$hint"    ]] && printf '  → %s\n' "$hint"
  [[ -n "$default" ]] && printf '  [detected: %s]\n' "$default"
  printf '  > '
  read -r input
  echo "${input:-$default}"
}

# ── gcloud install + auth check ───────────────────────────────────────────────
if ! command -v gcloud >/dev/null 2>&1; then
  printf '\ngcloud CLI not found.\n'
  if command -v brew >/dev/null 2>&1; then
    printf 'Installing via Homebrew...\n'
    brew install --cask google-cloud-sdk
    # shellcheck source=/dev/null
    source "$(brew --prefix)/share/google-cloud-sdk/path.bash.inc" 2>/dev/null || true
  else
    printf 'Install it from: https://cloud.google.com/sdk/docs/install\n'
    printf 'Then re-run this script.\n'
    exit 1
  fi
fi

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
if [[ -z "$ACTIVE_ACCOUNT" ]]; then
  printf '\nNot authenticated with gcloud.\n'
  printf '  Run: gcloud auth login\n'
  printf '  Or:  https://console.cloud.google.com\n'
  exit 1
fi

printf '\nAuthenticated as: %s\n' "$ACTIVE_ACCOUNT"

# ── detect from gcloud config ─────────────────────────────────────────────────
DETECTED_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
DETECTED_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
DETECTED_REGION="${DETECTED_REGION:-us-central1}"

DETECTED_REGISTRY=""
if [[ -n "$DETECTED_PROJECT" ]]; then
  DETECTED_REGISTRY=$(gcloud artifacts repositories list \
    --project="$DETECTED_PROJECT" \
    --location="$DETECTED_REGION" \
    --format="value(name)" 2>/dev/null | head -1 || true)
  DETECTED_REGISTRY="${DETECTED_REGISTRY##*/}"
fi

DETECTED_TAG=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d)

# ── prompt ────────────────────────────────────────────────────────────────────
printf '\n=== deployment config ===\n'

GCP_PROJECT=$(ask \
  "GCP project ID" \
  "Find it at: https://console.cloud.google.com — top nav project selector, or: gcloud projects list" \
  "$DETECTED_PROJECT")
[[ -n "$GCP_PROJECT" ]] || { printf '\nProject ID is required.\n' >&2; exit 1; }

GCP_REGION=$(ask \
  "Region" \
  "Common: us-central1, us-east1, europe-west1 — or: gcloud compute regions list" \
  "$DETECTED_REGION")

REGISTRY=$(ask \
  "Artifact Registry repo name" \
  "Find it at: https://console.cloud.google.com/artifacts?project=${GCP_PROJECT} — or: gcloud artifacts repositories list --project=${GCP_PROJECT} --location=${GCP_REGION}" \
  "$DETECTED_REGISTRY")
[[ -n "$REGISTRY" ]] || { printf '\nRegistry repo name is required.\n' >&2; exit 1; }

TAG=$(ask \
  "Image tag" \
  "Leave blank to use the detected git hash" \
  "$DETECTED_TAG")

IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REGISTRY}/frontend:${TAG}"

# ── confirm ───────────────────────────────────────────────────────────────────
printf '\nWill build and push:\n'
printf '  %s\n' "$IMAGE"
printf 'Then deploy to Cloud Run in %s.\n' "$GCP_REGION"
printf '\nProceed? [y/N] '
read -r yn
[[ "$yn" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

# ── build & push ──────────────────────────────────────────────────────────────
printf '\n[1/3] configuring docker auth...\n'
gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet

printf '[2/3] building image...\n'
docker build --platform linux/amd64 -t "$IMAGE" "$ROOT_DIR"

printf '[3/3] pushing image...\n'
docker push "$IMAGE"

# ── deploy ────────────────────────────────────────────────────────────────────
printf '\n=== deploying to Cloud Run ===\n'
gcloud run deploy dashboard-frontend \
  --image "$IMAGE" \
  --region "$GCP_REGION" \
  --project "$GCP_PROJECT"

printf '\nDone. Service URL:\n  '
gcloud run services describe dashboard-frontend \
  --region "$GCP_REGION" \
  --project "$GCP_PROJECT" \
  --format="value(status.url)"
