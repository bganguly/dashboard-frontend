#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
ENV_FILE="$ROOT_DIR/../springboot-dashboard-backend-gcp/.env.gcp"

printf '\n=== dashboard-frontend-gcp teardown ===\n'
printf '  [1] Local  — stop local dev server (default)\n'
printf '  [2] Remote — destroy GCP frontend infrastructure\n'
printf '\nChoice [1/2]: '
read -r _MODE
case "$_MODE" in
  2) _TARGET="remote" ;;
  *) _TARGET="local" ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# LOCAL
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$_TARGET" == "local" ]]; then
  printf '\nStopping local frontend (port 3006)...\n'
  "$ROOT_DIR/scripts/free-port.sh" 3006
  printf 'Local infrastructure torn down.\n'
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# REMOTE (GCP)
# ══════════════════════════════════════════════════════════════════════════════

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

PULUMI_USER=$(pulumi whoami 2>/dev/null || true)
[[ -n "$PULUMI_USER" ]] || { printf 'Not logged in to Pulumi. Run: pulumi login\n' >&2; exit 1; }

DETECTED_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
GCP_PROJECT="${DETECTED_PROJECT:-${GCP_PROJECT:-}}"
[[ -n "$GCP_PROJECT" ]] || { printf 'No GCP project detected. Run: gcloud config set project <id>\n' >&2; exit 1; }

DETECTED_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
GCP_REGION="${DETECTED_REGION:-${GCP_REGION:-us-central1}}"

printf '\nThis will destroy the frontend GCP resources in project %s (%s).\n' "$GCP_PROJECT" "$GCP_REGION"
printf 'Removes: dash-frontend Cloud Run service, IAM bindings.\n'
printf '\nProceed? [Y/n] '
read -r yn
[[ -z "$yn" || "$yn" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

cd "$INFRA_DIR"
npm install --prefer-offline 2>/dev/null || npm install

pulumi stack select "dev"
pulumi config set gcp:project "$GCP_PROJECT"
pulumi config set gcp:region  "$GCP_REGION"
pulumi destroy --yes

printf '\n[infra-down] frontend GCP resources destroyed.\n'
printf 'Note: Cloud SQL, VPC, and backend Cloud Run remain — run infra-down.sh from springboot-dashboard-backend-gcp to remove those.\n'
