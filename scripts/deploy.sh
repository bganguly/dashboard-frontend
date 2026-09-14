#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
BACKEND_INFRA_DIR="$(cd "$ROOT_DIR/../springboot-dashboard-backend/infra" 2>/dev/null && pwd || true)"
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
_MODE_FROM_ENV=0
if [[ -n "${DEPLOY_MODE:-}" ]]; then
  _TARGET="remote"
  _MODE_FROM_ENV=1
  printf '\n  (DEPLOY_MODE=%s — skipping menu)\n' "$DEPLOY_MODE"
else
  printf '\nChoice [1/2/3]: '
  read -r _MODE
  case "$_MODE" in
    2) _TARGET="remote"; DEPLOY_MODE="lite" ;;
    3) _TARGET="remote"; DEPLOY_MODE="full" ;;
    *) _TARGET="local";  DEPLOY_MODE=""    ;;
  esac
fi

if [[ "$_TARGET" == "remote" ]]; then
  ENV_FILE="$ROOT_DIR/../springboot-dashboard-backend-gcp/.env.gcp.${DEPLOY_MODE}"
  FRONTEND_ENV_FILE="$ROOT_DIR/.env.gcp.${DEPLOY_MODE}"
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

  if (( ! _MODE_FROM_ENV )); then
    printf 'Proceed? [Y/n] '
    read -r _CONFIRM
    [[ -z "$_CONFIRM" || "$_CONFIRM" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }
  fi
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
printf 'Auth: %s\n' "$ACTIVE_ACCOUNT"

printf '\n=== deployment config ===\n'

_CONFIG_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
GCP_PROJECT="${_CONFIG_PROJECT:-${GCP_PROJECT:-}}"
[[ -n "$GCP_PROJECT" ]] || { printf '\nNo GCP project detected. Run: gcloud config set project <id>\n' >&2; exit 1; }

_CONFIG_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
GCP_REGION="${_CONFIG_REGION:-${GCP_REGION:-us-central1}}"

_shasum() { shasum -a 256 "$@" 2>/dev/null || sha256sum "$@" 2>/dev/null; }
DEMO_SCALE="$( [[ "$DEPLOY_MODE" == "full" ]] && printf '~4M demo orders' || printf '~500K demo orders' )"

TAG=$(find "$ROOT_DIR/src" "$ROOT_DIR/Dockerfile" \
    "$ROOT_DIR/index.html" "$ROOT_DIR/package.json" "$ROOT_DIR/vite.config"* \
    -type f 2>/dev/null | sort | xargs cat 2>/dev/null \
  | _shasum | cut -c1-16 || true)
TAG="${TAG:-$(date +%Y%m%d%H%M%S)}"

printf '  Project: %s  Region: %s\n' "$GCP_PROJECT" "$GCP_REGION"

if [[ "$DEPLOY_MODE" == "lite" ]]; then
  DEPLOY_TARGET="cloudrun"
  printf '\n  [lite] Skipping GKE — deploying to Cloud Run.\n'
else
  _GKE_EXISTS=$(gcloud container clusters describe "${GKE_CLUSTER:-dash-gke-cluster}" \
    --zone "${GCP_REGION}-a" --project "$GCP_PROJECT" --format="value(name)" 2>/dev/null || true)
  _CR_EXISTS=$(gcloud run services describe dash-react-frontend \
    --region "$GCP_REGION" --project "$GCP_PROJECT" --format="value(name)" 2>/dev/null || true)
  if [[ -n "$_GKE_EXISTS" ]]; then
    DEPLOY_TARGET="gke"
    printf '\n  GKE cluster detected — redeploying to GKE.\n'
  elif [[ -n "$_CR_EXISTS" ]]; then
    DEPLOY_TARGET="cloudrun"
    printf '\n  Cloud Run service detected — redeploying to Cloud Run.\n'
  else
    printf '\n  No existing deployment detected.\n'
    printf '  Continue to deploy to Cloud Run? [Y/n]: '
    read -r _CHOICE
    case "${_CHOICE:-Y}" in
      [nN]*) DEPLOY_TARGET="gke" ;;
      *)     DEPLOY_TARGET="cloudrun" ;;
    esac
    printf '\n  Target: %s\n' "$DEPLOY_TARGET"
  fi
fi

GKE_CLUSTER="${GKE_CLUSTER:-dash-gke-cluster}"
K8S_NAMESPACE="dash"

BACKEND_URL="${BACKEND_URL:-}"
if [[ -z "$BACKEND_URL" ]]; then
if [[ "$DEPLOY_TARGET" == "gke" ]]; then
  GKE_ZONE="${GCP_REGION}-a"
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
  if [[ -n "$BACKEND_INFRA_DIR" && -d "$BACKEND_INFRA_DIR" ]] && command -v pulumi >/dev/null 2>&1; then
    BACKEND_URL=$(cd "$BACKEND_INFRA_DIR" && \
      pulumi stack select "$DEPLOY_MODE" 2>/dev/null && \
      pulumi stack output backendUrl 2>/dev/null || true)
  fi
  if [[ -z "$BACKEND_URL" ]]; then
    _LB_NS="${DEPLOY_MODE_PREFIX:-dash-lite}"
    _SDK_BIN="$(gcloud info --format='value(installation.sdk_root)')/bin"
    export PATH="${_SDK_BIN}:${PATH}"
    gcloud container clusters get-credentials "${_LB_NS}-cluster" \
      --zone "${GCP_REGION}-a" --project "$GCP_PROJECT" --quiet 2>/dev/null || true
    _IP=$(kubectl get svc "${_LB_NS}-backend" -n "${_LB_NS}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$_IP" ]] && BACKEND_URL="http://${_IP}"
  fi
fi
fi
if [[ -z "$BACKEND_URL" ]]; then
  printf '\nCould not resolve backend URL automatically.\n'
  printf 'Enter backend URL (or press Enter to abort): '
  read -r _MANUAL_URL
  [[ -n "$_MANUAL_URL" ]] || { printf 'Aborted.\n'; exit 1; }
  BACKEND_URL="$_MANUAL_URL"
fi


_FE_PREFIX=$([[ "$DEPLOY_MODE" == "lite" ]] && printf 'dash-react-lite' || printf 'dash-react')
REGISTRY="${_FE_PREFIX}-frontend-repo"

if ! gcloud artifacts repositories describe "$REGISTRY" \
      --project="$GCP_PROJECT" --location="$GCP_REGION" >/dev/null 2>&1; then
  printf '  Creating repo "%s"...\n' "$REGISTRY"
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
  printf '  Image %s exists — skipping build.\n' "$TAG"
else
  printf 'Building: %s\n' "$IMAGE"

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

  local cache_tag tmpyaml
  cache_tag="${tag%:*}:cache"
  tmpyaml=$(mktemp /tmp/cloudbuild.XXXXXX)
  cat > "$tmpyaml" <<YAML
steps:
- name: 'gcr.io/cloud-builders/docker'
  entrypoint: bash
  args:
  - -c
  - |
    docker pull '${cache_tag}' 2>/dev/null || true
    docker build --cache-from '${cache_tag}' -t '${tag}' -t '${cache_tag}' .
- name: 'gcr.io/cloud-builders/docker'
  args: [push, '${tag}']
- name: 'gcr.io/cloud-builders/docker'
  args: [push, '${cache_tag}']
images:
- '${tag}'
- '${cache_tag}'
YAML
  local attempt=0 rc
  while (( attempt < 3 )); do
    attempt=$(( attempt + 1 ))
    set +e; gcloud builds submit --config "$tmpyaml" --project "$project" "$srcdir"; rc=$?; set -e
    [[ "$rc" == "0" ]] && { rm -f "$tmpyaml"; return 0; }
    [[ "$rc" == "130" ]] && { printf '\n[deploy] Build cancelled.\n'; rm -f "$tmpyaml"; exit 130; }
    (( attempt < 3 )) && { printf '  Cloud Build submit failed (attempt %d/3) — waiting 20s for IAM propagation...\n' "$attempt"; sleep 20; }
  done
  rm -f "$tmpyaml"
  printf '[deploy] Cloud Build failed after 3 attempts.\n' >&2
  return 1
}

if docker info >/dev/null 2>&1; then
  gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet
  docker build --platform linux/amd64 -t "$IMAGE" "$ROOT_DIR"
  docker push "$IMAGE"
else
  _cloudbuild_submit "$IMAGE" "$GCP_PROJECT" "$ROOT_DIR"
fi
fi
rm -f "$ROOT_DIR/.env.production"

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf 'Setting up ADC (required by Pulumi)...\n'
  gcloud auth application-default login
fi


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
  if [[ -n "$_IMG_EXISTS" ]]; then
    _DEPLOYED_IMG=$(gcloud run services describe "${_FE_PREFIX}-frontend" \
      --region "$GCP_REGION" --project "$GCP_PROJECT" \
      --format="value(spec.template.spec.containers[0].image)" 2>/dev/null || true)
    if [[ "$_DEPLOYED_IMG" == "$IMAGE" ]]; then
      printf '  Cloud Run already serving %s — skipping Pulumi.\n' "$TAG"
      FRONTEND_URL=$(gcloud run services describe "${_FE_PREFIX}-frontend" \
        --region "$GCP_REGION" --project "$GCP_PROJECT" \
        --format="value(status.url)" 2>/dev/null || true)
      printf 'GCP_PROJECT=%s\nFRONTEND_URL=%s\n' "$GCP_PROJECT" "${FRONTEND_URL:-}" > "$FRONTEND_ENV_FILE"
      printf '\nFrontend unchanged. URL:\n  %s\n' "${FRONTEND_URL:-}"
      exit 0
    fi
  fi

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
    pulumi config set namePrefix       "dash-react-lite"
    pulumi config set minInstanceCount "0"
    pulumi config set maxInstanceCount "1"
    pulumi config set cpu              "1"
    pulumi config set memory           "512Mi"
  else
    pulumi config set namePrefix       "dash-react"
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

