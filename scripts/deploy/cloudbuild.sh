#!/usr/bin/env bash

_cloudbuild_submit() {
  local tag="$1" project="$2" srcdir="$3"
  gcloud services enable cloudbuild.googleapis.com --project "$project"

  local _CB_ROLE
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

  local cache_tag tmpyaml attempt rc
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
  attempt=0 rc=0
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
