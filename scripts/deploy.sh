#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
BACKEND_INFRA_DIR="$(cd "$ROOT_DIR/../springboot-dashboard-backend-gcp/infra" 2>/dev/null && pwd || true)"
ENV_FILE=""
cd "$ROOT_DIR"

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
_local_running=0
_lite_count=0
_full_count=0
lsof -ti:3006 >/dev/null 2>&1 && _local_running=1 || true
if command -v pulumi >/dev/null 2>&1 && pulumi whoami >/dev/null 2>&1; then
  _lite_count=$(_pulumi_stack_count lite)
  _full_count=$(_pulumi_stack_count full)
fi

printf '\n=== dashboard-frontend-gcp ===\n\n'
printf '  [1] Local  — Vite dev server on localhost (no GCP cost)'
(( _local_running )) && printf ' [running]' || printf ' [not detected]'
printf '\n'
printf '  [2] Lite   — GCP: Cloud Run (scales to zero, cold starts OK)'
(( _lite_count > 0 )) && printf ' [%s resources active]' "$_lite_count" || printf ' [not deployed]'
printf '\n'
printf '  [3] Full   — GCP: Cloud Run (min 1 instance, always warm)'
(( _full_count > 0 )) && printf ' [%s resources active]' "$_full_count" || printf ' [not deployed]'
printf '               Full also unlocks GKE deployment.\n'
printf '\nChoice [1/2/3]: '
read -r _MODE
case "$_MODE" in
  2) _TARGET="remote"; DEPLOY_MODE="lite" ;;
  3) _TARGET="remote"; DEPLOY_MODE="full" ;;
  *) _TARGET="local";  DEPLOY_MODE=""    ;;
esac

if [[ "$_TARGET" == "remote" ]]; then
  ENV_FILE="$ROOT_DIR/../springboot-dashboard-backend-gcp/.env.gcp.${DEPLOY_MODE}"
  FRONTEND_ENV_FILE="$ROOT_DIR/.env.gcp.${DEPLOY_MODE}"
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

  if [[ "$DEPLOY_MODE" == "lite" ]]; then
    printf '\n--- Lite GCP summary ---\n'
    printf '  Cloud Run:  min=0 instances (cold starts ~3s), max=1, 1 CPU / 256 Mi\n'
    printf '  GKE:        skipped\n'
    printf '  Cost est:   ~$5-10/mo if left running\n'
  else
    printf '\n--- Full GCP summary ---\n'
    printf '  Cloud Run:  min=1 instance (always warm), max=3, 1 CPU / 512 Mi\n'
    printf '  GKE:        available (you will be prompted)\n'
    printf '  Cost est:   ~$20-40/mo if left running\n'
  fi
  printf '\nProceed? [Y/n] '
  read -r _CONFIRM
  [[ -z "$_CONFIRM" || "$_CONFIRM" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }
fi

# ══════════════════════════════════════════════════════════════════════════════
# LOCAL
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$_TARGET" == "local" ]]; then

  command -v node >/dev/null 2>&1 || { printf 'Node.js not found — install Node 20+\n' >&2; exit 1; }

  printf '\nInstalling deps...\n'
  npm install --prefer-offline 2>/dev/null || npm install

  printf '\nFreeing port 3006...\n'
  "$ROOT_DIR/scripts/free-port.sh" 3006

  BACKEND_URL="${BACKEND_URL:-http://localhost:8080}"
  printf 'Starting Vite dev server on :3006 (BACKEND_URL=%s)...\n' "$BACKEND_URL"
  printf 'Override: BACKEND_URL=http://other-host:port ./scripts/deploy.sh\n\n'

  BACKEND_URL="$BACKEND_URL" npm run dev

  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# REMOTE (GCP)
# ══════════════════════════════════════════════════════════════════════════════

if ! command -v gcloud >/dev/null 2>&1; then
  printf '\ngcloud CLI not found.\n'
  if command -v brew >/dev/null 2>&1; then
    printf 'Installing via Homebrew...\n'
    brew install --cask google-cloud-sdk
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

printf '\n=== deployment config ===\n'

_CONFIG_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
GCP_PROJECT="${_CONFIG_PROJECT:-${GCP_PROJECT:-}}"
[[ -n "$GCP_PROJECT" ]] || { printf '\nNo GCP project detected. Run: gcloud config set project <id>\n' >&2; exit 1; }

_CONFIG_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
GCP_REGION="${_CONFIG_REGION:-${GCP_REGION:-us-central1}}"

_shasum() { shasum -a 256 "$@" 2>/dev/null || sha256sum "$@" 2>/dev/null; }
DEMO_SCALE="$( [[ "$DEPLOY_MODE" == "full" ]] && printf '~4M demo orders' || printf '~500K demo orders' )"

TAG=$(find "$ROOT_DIR/src" "$ROOT_DIR/Dockerfile" \
    "$ROOT_DIR/package.json" "$ROOT_DIR/vite.config"* \
    -type f 2>/dev/null | sort | xargs cat 2>/dev/null \
  | _shasum | cut -c1-16 || true)
TAG="${TAG:-$(date +%Y%m%d%H%M%S)}"

printf '  Project: %s\n  Region:  %s\n' "$GCP_PROJECT" "$GCP_REGION"

if [[ "$DEPLOY_MODE" == "lite" ]]; then
  DEPLOY_TARGET="cloudrun"
  printf '\n  [lite] Skipping GKE — deploying to Cloud Run.\n'
else
  _GKE_EXISTS=$(gcloud container clusters describe "${GKE_CLUSTER:-dash-gke-cluster}" \
    --zone "${GCP_REGION}-a" --project "$GCP_PROJECT" --format="value(name)" 2>/dev/null || true)
  _CR_EXISTS=$(gcloud run services describe dash-frontend \
    --region "$GCP_REGION" --project "$GCP_PROJECT" --format="value(name)" 2>/dev/null || true)
  if [[ -n "$_GKE_EXISTS" ]]; then
    DEPLOY_TARGET="gke"
    printf '\n  GKE cluster detected — redeploying to GKE.\n'
  elif [[ -n "$_CR_EXISTS" ]]; then
    DEPLOY_TARGET="cloudrun"
    printf '\n  Cloud Run service detected — redeploying to Cloud Run.\n'
  else
    printf '\n=== STOPPED ===================================================\n'
    printf '  Deploy to GKE (Kubernetes)?  Y = GKE  /  n = Cloud Run\n'
    printf '===============================================================\n'
    read -r -p "Deploy to GKE? [Y/n]: " _CHOICE
    case "$_CHOICE" in
      [nN]*) DEPLOY_TARGET="cloudrun" ;;
      *)     DEPLOY_TARGET="gke" ;;
    esac
    printf '\n  Target: %s\n' "$DEPLOY_TARGET"
  fi
fi

GKE_CLUSTER="${GKE_CLUSTER:-dash-gke-cluster}"
K8S_NAMESPACE="dash"

BACKEND_URL=""
if [[ "$DEPLOY_TARGET" == "gke" ]]; then
  GKE_ZONE="${GCP_REGION}-a"
  printf '\n  Resolving backend URL from GKE ingress (zone: %s)...\n' "$GKE_ZONE"
  if ! command -v kubectl >/dev/null 2>&1; then
    printf '  kubectl not found — installing via gcloud components...\n'
    gcloud components install kubectl --quiet
  fi
  _SDK_BIN="$(gcloud info --format='value(installation.sdk_root)')/bin"
  export PATH="${_SDK_BIN}:${PATH}"
  gcloud container clusters get-credentials "$GKE_CLUSTER" \
    --zone "$GKE_ZONE" --project "$GCP_PROJECT"
  _IP=$(kubectl get ingress dash-backend -n "$K8S_NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "$_IP" ]] && BACKEND_URL="http://${_IP}"
else
  printf '\n  Resolving backend URL from Pulumi stack...\n'
  if [[ -n "$BACKEND_INFRA_DIR" && -d "$BACKEND_INFRA_DIR" ]] && command -v pulumi >/dev/null 2>&1; then
    BACKEND_URL=$(cd "$BACKEND_INFRA_DIR" && \
      pulumi stack select "$DEPLOY_MODE" 2>/dev/null && \
      pulumi stack output backendUrl 2>/dev/null || true)
  fi
fi
[[ -n "$BACKEND_URL" ]] || { printf '\nCould not resolve backend URL — deploy the backend first.\n' >&2; exit 1; }

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

_IMG_EXISTS=$(gcloud artifacts docker tags list \
  "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REGISTRY}/frontend" \
  --filter="tag=${TAG}" \
  --format="value(tag)" \
  --project "$GCP_PROJECT" 2>/dev/null | head -1 || true)

printf 'VITE_DEMO_SCALE=%s\n' "$DEMO_SCALE" > "$ROOT_DIR/.env.production"

if [[ -n "$_IMG_EXISTS" ]]; then
  printf '\n  Image %s already exists — skipping build.\n' "$IMAGE"
else
  printf '\nBuilding and pushing:\n  %s\n' "$IMAGE"

_cloudbuild_submit() {
  local tag="$1" project="$2" srcdir="$3"
  gcloud services enable cloudbuild.googleapis.com --project "$project"

  _CB_ROLE=$(gcloud projects get-iam-policy "$project" \
    --flatten="bindings[].members" \
    --filter="bindings.members:user:${ACTIVE_ACCOUNT} AND (bindings.role:roles/cloudbuild OR bindings.role:roles/owner OR bindings.role:roles/editor)" \
    --format="value(bindings.role)" 2>/dev/null | head -1 || true)
  if [[ -z "$_CB_ROLE" ]]; then
    printf '  Granting Cloud Build Editor to %s...\n' "$ACTIVE_ACCOUNT"
    gcloud projects add-iam-policy-binding "$project" \
      --member="user:${ACTIVE_ACCOUNT}" \
      --role="roles/cloudbuild.builds.editor" --quiet
  fi

  local attempt=0
  while (( attempt < 3 )); do
    attempt=$(( attempt + 1 ))
    set +e
    gcloud builds submit --tag "$tag" --project "$project" "$srcdir"
    local rc=$?
    set -e
    [[ "$rc" == "0" ]] && return 0
    [[ "$rc" == "130" ]] && { printf '\n[deploy] Build cancelled.\n'; exit 130; }
    if (( attempt < 3 )); then
      printf '  Cloud Build submit failed (attempt %d/3) — waiting 20s for IAM propagation...\n' "$attempt"
      sleep 20
    fi
  done
  printf '[deploy] Cloud Build failed after 3 attempts.\n' >&2
  return 1
}

if docker info >/dev/null 2>&1; then
  printf '\n[1/3] configuring docker auth...\n'
  gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet
  printf '[2/3] building image...\n'
  docker build --platform linux/amd64 -t "$IMAGE" "$ROOT_DIR"
  printf '[3/3] pushing image...\n'
  docker push "$IMAGE"
else
  printf '\nDocker not available — building via Cloud Build...\n'
  _cloudbuild_submit "$IMAGE" "$GCP_PROJECT" "$ROOT_DIR"
fi
fi
rm -f "$ROOT_DIR/.env.production"

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf '\nSetting up Application Default Credentials (required by Pulumi)...\n'
  gcloud auth application-default login
fi

PORTFOLIO_EXPLORER="$(cd "$ROOT_DIR/../.." && pwd)/portfolio/orders-dashboard/api-explorer-${DEPLOY_MODE}.html"

if [[ "$DEPLOY_TARGET" == "gke" ]]; then
  printf '\n=== deploying to GKE via Cloud Build ===\n'
  printf '  Cluster: %s  Region: %s\n' "$GKE_CLUSTER" "$GCP_REGION"

  gcloud services enable cloudbuild.googleapis.com container.googleapis.com \
    --project "$GCP_PROJECT" --quiet

  gcloud builds submit "$ROOT_DIR/k8s" \
    --config "$ROOT_DIR/cloudbuild-gke.yaml" \
    --substitutions "_IMAGE=${IMAGE},_BACKEND_URL=${BACKEND_URL},_CLUSTER=${GKE_CLUSTER},_ZONE=${GKE_ZONE},_NAMESPACE=${K8S_NAMESPACE}" \
    --project "$GCP_PROJECT"

  FRONTEND_URL="<check GKE ingress — see Cloud Build output above>"
  printf '\nDone. Check ingress IP in Cloud Build output above.\n'
else
  printf '\n=== deploying via Pulumi ===\n'

  _pulumi_up_robust() {
    local log_file
    log_file="$(mktemp)"
    local attempt=0 rc

    while (( attempt < 5 )); do
      attempt=$(( attempt + 1 ))
      set +e
      pulumi up --yes 2>&1 | tee "$log_file"
      rc="${PIPESTATUS[0]}"
      set -e

      [[ "$rc" == "0" ]] && { rm -f "$log_file"; return 0; }

      local conflicts
      conflicts=$(python3 - "${log_file}" <<'PYEOF'
import re, sys
content = open(sys.argv[1]).read()
lines = content.split('\n')
seen = set()
for i, line in enumerate(lines):
    m = re.match(r'\s+(gcp:[^(]+)\(([^)]+)\):', line)
    if m:
        type_display = m.group(1).strip()
        logical_name = m.group(2).strip()
        for j in range(i, min(i+8, len(lines))):
            id_m = re.search(r"'([^']+)' already exists", lines[j])
            if id_m:
                key = f'{type_display}|{logical_name}|{id_m.group(1)}'
                if key not in seen:
                    seen.add(key)
                    print(key)
                break
PYEOF
      2>/dev/null || true)

      if [[ -z "$conflicts" ]]; then
        rm -f "$log_file"
        printf '[deploy] pulumi up failed with no importable conflicts — cannot auto-recover.\n' >&2
        return 1
      fi

      printf '[deploy] Auto-importing conflicting resources (attempt %d)...\n' "$attempt"
      while IFS='|' read -r type_display logical_name gcp_id; do
        [[ -z "$type_display" ]] && continue
        local module type_name import_type
        module=$(printf '%s' "$type_display" | cut -d: -f2)
        type_name=$(printf '%s' "$type_display" | cut -d: -f3)
        import_type="gcp:${module}/${type_name,}:${type_name}"
        printf '  importing: %s %s = %s\n' "$import_type" "$logical_name" "$gcp_id"
        pulumi import "$import_type" "$logical_name" "$gcp_id" --yes 2>/dev/null || true
      done <<< "$conflicts"
    done

    rm -f "$log_file"
    printf '[deploy] pulumi up failed after %d attempts.\n' "$attempt" >&2
    return 1
  }

  cd "$INFRA_DIR"
  npm install --prefer-offline 2>/dev/null || npm install
  pulumi stack select "$DEPLOY_MODE" 2>/dev/null || pulumi stack init "$DEPLOY_MODE"
  pulumi config set gcp:project   "$GCP_PROJECT"
  pulumi config set gcp:region    "$GCP_REGION"
  pulumi config set backendUrl    "$BACKEND_URL"
  pulumi config set frontendImage "$IMAGE"
  if [[ "$DEPLOY_MODE" == "lite" ]]; then
    pulumi config set namePrefix       "dash-lite"
    pulumi config set minInstanceCount "0"
    pulumi config set maxInstanceCount "1"
    pulumi config set cpu              "1"
    pulumi config set memory           "512Mi"
  else
    pulumi config set namePrefix       "dash"
    pulumi config set minInstanceCount "1"
    pulumi config set maxInstanceCount "3"
    pulumi config set cpu              "1"
    pulumi config set memory           "512Mi"
  fi
  _pulumi_up_robust

  FRONTEND_URL=$(pulumi stack output frontendUrl 2>/dev/null || true)
  printf 'GCP_PROJECT=%s\nFRONTEND_URL=%s\n' "$GCP_PROJECT" "$FRONTEND_URL" > "$FRONTEND_ENV_FILE"
  printf '\nDone. Frontend URL:\n  %s\n' "$FRONTEND_URL"
fi

if [[ -n "$FRONTEND_URL" && -f "$PORTFOLIO_EXPLORER" ]]; then
  sed -i '' "s|^    const BASE = .*;.*$|    const BASE = '${FRONTEND_URL}/api';|" "$PORTFOLIO_EXPLORER"
  sed -i '' "s|^    const DEMO_SCALE = .*;.*$|    const DEMO_SCALE = '${DEMO_SCALE}';|" "$PORTFOLIO_EXPLORER"
  printf '\nPatched portfolio API Explorer BASE → %s/api, DEMO_SCALE → %s\n' "$FRONTEND_URL" "$DEMO_SCALE"
elif [[ ! -f "$PORTFOLIO_EXPLORER" ]]; then
  printf '\n(Portfolio api-explorer.html not found — update BASE manually)\n'
fi

PORTFOLIO_SET_LIVE="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/portfolio/scripts/set-live-url.sh"
if [[ -n "$FRONTEND_URL" && -f "$PORTFOLIO_SET_LIVE" ]]; then
  printf '\nUpdating portfolio live-urls.js...\n'
  bash "$PORTFOLIO_SET_LIVE" --tier "$DEPLOY_MODE" dashboard "$FRONTEND_URL"
fi
