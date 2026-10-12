#!/usr/bin/env bash

_deploy_cloudrun() {
  local _IMG_EXISTS _DEPLOYED_IMG
  _IMG_EXISTS=$(gcloud artifacts docker tags list \
    "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${REGISTRY}/frontend" \
    --filter="tag=${TAG}" --format="value(tag)" \
    --project "$GCP_PROJECT" 2>/dev/null | head -1 || true)

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
      return
    fi
  fi

  printf '\n=== deploying via Pulumi ===\n'

  if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    printf 'Setting up ADC (required by Pulumi)...\n'
    gcloud auth application-default login
  fi

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
  elif [[ "$DEPLOY_MODE" == "angular" ]]; then
    pulumi config set namePrefix       "dash-angular"
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
}
