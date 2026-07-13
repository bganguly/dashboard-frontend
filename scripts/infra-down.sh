#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"

_local_running=0
_lite_count=0
_full_count=0

lsof -ti:3006 >/dev/null 2>&1 && _local_running=1 || true

_pulumi_stack_count() {
  local stack="$1"
  ( cd "$INFRA_DIR" 2>/dev/null && \
    pulumi stack ls --json 2>/dev/null | python3 -c "
import json,sys
try:
    data=json.load(sys.stdin)
    for s in data:
        if s.get('name')=='$stack':
            print(s.get('resourceCount',0))
            sys.exit(0)
    print(0)
except Exception:
    print(0)
" 2>/dev/null ) || printf '0'
}

if command -v pulumi >/dev/null 2>&1 && pulumi whoami >/dev/null 2>&1; then
  _lite_count=$(_pulumi_stack_count lite)
  _full_count=$(_pulumi_stack_count full)
fi

_CHAINED=0
if [[ -n "${DEPLOY_MODE:-}" ]]; then
  _TARGET="remote"
  _CHAINED=1
  printf '\n=== dashboard-frontend-gcp teardown (chained, mode: %s) ===\n' "$DEPLOY_MODE"
else
  printf '\n=== dashboard-frontend-gcp teardown ===\n\n'
  printf '  [1] Local  — stop local dev server'
  (( _local_running )) && printf ' [running]' || printf ' [not detected]'
  printf '\n'
  printf '  [2] Lite   — destroy GCP lite (Cloud Run frontend, dash-lite-*)'
  (( _lite_count > 0 )) && printf ' [%s resources active]' "$_lite_count" || printf ' [not deployed]'
  printf '\n'
  printf '  [3] Full   — destroy GCP full (Cloud Run frontend, dash-*)'
  (( _full_count > 0 )) && printf ' [%s resources active]' "$_full_count" || printf ' [not deployed]'
  printf '\nChoice [1/2/3]: '
  read -r _MODE
  case "$_MODE" in
    2) _TARGET="remote"; DEPLOY_MODE="lite" ;;
    3) _TARGET="remote"; DEPLOY_MODE="full" ;;
    *)  _TARGET="local";  DEPLOY_MODE=""    ;;
  esac
fi

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

FRONTEND_ENV_FILE="$ROOT_DIR/.env.gcp.${DEPLOY_MODE}"
[[ -f "$FRONTEND_ENV_FILE" ]] && source "$FRONTEND_ENV_FILE"

PULUMI_USER=$(pulumi whoami 2>/dev/null || true)
[[ -n "$PULUMI_USER" ]] || { printf 'Not logged in to Pulumi. Run: pulumi login\n' >&2; exit 1; }

DETECTED_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
GCP_PROJECT="${DETECTED_PROJECT:-${GCP_PROJECT:-}}"
[[ -n "$GCP_PROJECT" ]] || { printf 'No GCP project detected. Run: gcloud config set project <id>\n' >&2; exit 1; }

DETECTED_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
GCP_REGION="${DETECTED_REGION:-${GCP_REGION:-us-central1}}"

printf '\nThis will destroy the frontend GCP resources in project %s (%s).\n' "$GCP_PROJECT" "$GCP_REGION"
printf 'Removes: dash-frontend Cloud Run service, IAM bindings.\n'
if (( _CHAINED == 0 )); then
  printf '\nProceed? [Y/n] '
  read -r yn
  [[ -z "$yn" || "$yn" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }
fi

cd "$INFRA_DIR"
npm install --prefer-offline 2>/dev/null || npm install

pulumi stack select "$DEPLOY_MODE"
pulumi config set gcp:project "$GCP_PROJECT"
pulumi config set gcp:region  "$GCP_REGION"

_EXPECTED_PREFIX=$([[ "$DEPLOY_MODE" == "lite" ]] && printf 'dash-lite' || printf 'dash')
_STACK_PREFIX=$(pulumi config get namePrefix 2>/dev/null || true)
if [[ -n "$_STACK_PREFIX" && "$_STACK_PREFIX" != "$_EXPECTED_PREFIX" ]]; then
  printf '\n[infra-down] WARNING: %s stack has namePrefix=%s but expected %s.\n' "$DEPLOY_MODE" "$_STACK_PREFIX" "$_EXPECTED_PREFIX" >&2
  printf '  This stack may contain resources from a different mode — destroying may affect other environments.\n' >&2
  printf 'Proceed anyway? [y/N] '
  read -r _SAFEGUARD
  [[ "$_SAFEGUARD" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }
fi
printf '\n[infra-down] Targeting namePrefix=%s (only %s-* GCP resources will be deleted).\n' "$_EXPECTED_PREFIX" "$_EXPECTED_PREFIX"

_pulumi_destroy_robust() {
  local log_file
  log_file="$(mktemp)"
  local attempt=0 rc stale_urns

  while true; do
    attempt=$(( attempt + 1 ))
    set +e
    pulumi destroy --yes 2>&1 | tee "$log_file"
    rc="${PIPESTATUS[0]}"
    set -e

    if [[ "$rc" == "0" ]]; then
      rm -f "$log_file"
      return 0
    fi

    stale_urns=$(grep -oE 'error: deleting urn:pulumi:[^ ]+' "$log_file" \
      | sed 's/^error: deleting //; s/:$//' | sort -u || true)

    if [[ -z "$stale_urns" ]]; then
      rm -f "$log_file"
      printf '[infra-down] pulumi destroy failed with no extractable URNs — cannot auto-recover.\n' >&2
      return 1
    fi

    printf '[infra-down] Auto-purging stale state entries (attempt %d)...\n' "$attempt"
    while IFS= read -r urn; do
      [[ -z "$urn" ]] && continue
      printf '  purging: %s\n' "$urn"
      pulumi state delete "$urn" --yes 2>/dev/null || true
    done <<< "$stale_urns"
  done
}

_pulumi_destroy_robust

rm -f "$FRONTEND_ENV_FILE"
printf '\n[infra-down] frontend GCP %s resources destroyed.\n' "$DEPLOY_MODE"
printf 'Note: Cloud SQL, VPC, and backend Cloud Run remain — run infra-down.sh from springboot-dashboard-backend-gcp to remove those.\n'
