#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"
BACKEND_INFRA_DIR="$(cd "$ROOT_DIR/../springboot-dashboard-backend-gcp/infra" 2>/dev/null && pwd || true)"
ENV_FILE="$ROOT_DIR/../springboot-dashboard-backend-gcp/.env.gcp"
cd "$ROOT_DIR"

printf '\n=== dashboard-frontend-gcp ===\n'
printf '  [1] Local  — start local dev server (default)\n'
printf '  [2] Remote — deploy to GCP (Cloud Run or GKE)\n'
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

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

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

printf '\n=== STOPPED ===================================================\n'
printf '  Deploy to GKE (Kubernetes)?  Y = GKE  /  n = Cloud Run\n'
printf '===============================================================\n'
read -r -p "Deploy to GKE? [Y/n]: " _CHOICE
case "$_CHOICE" in
  [nN]*) DEPLOY_TARGET="cloudrun" ;;
  *)     DEPLOY_TARGET="gke" ;;
esac
printf '\n  Target: %s\n' "$DEPLOY_TARGET"

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
printf '\nBuilding and pushing:\n  %s\n' "$IMAGE"

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

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf '\nSetting up Application Default Credentials (required by Pulumi)...\n'
  gcloud auth application-default login
fi

PORTFOLIO_EXPLORER="$(cd "$ROOT_DIR/../.." && pwd)/portfolio/orders-dashboard/api-explorer.html"

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
fi

if [[ -n "$FRONTEND_URL" && -f "$PORTFOLIO_EXPLORER" ]]; then
  sed -i '' "s|const BASE = '.*';|const BASE = '${FRONTEND_URL}/api';|" "$PORTFOLIO_EXPLORER"
  printf '\nPatched portfolio API Explorer BASE → %s/api\n' "$FRONTEND_URL"
elif [[ ! -f "$PORTFOLIO_EXPLORER" ]]; then
  printf '\n(Portfolio api-explorer.html not found — update BASE manually)\n'
fi
