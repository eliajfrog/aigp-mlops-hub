#!/usr/bin/env bash
# =============================================================================
# evidence/promote-lib.sh — AppTrust version lifecycle management library
#
# AIGP BoK: Domain IV — Conformity assessment, promotion gates
# EU AI Act: Art. 9   — Risk management gates before production
# EU AI Act: Art. 14  — Human oversight and control
#
# Usage: Source this file — do not execute directly
#   source evidence/promote-lib.sh
#
# Required env vars (injected by CI job env block):
#   JPD_URL         — e.g. https://tsmemea.jfrog.io
#   JF_ADMIN_TOKEN  — admin token for AppTrust REST API calls
#   APPLICATION_KEY — e.g. aigp-devops-helper-llm
#   APP_VERSION     — e.g. 2.1.5
#   STAGE_DEV       — aigp-demo-DEV
#   STAGE_QA        — aigp-demo-QA
#   STAGE_PROD      — PROD
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "[ERROR] promote-lib.sh must be sourced, not executed directly"
  exit 1
fi

_promo_log() { echo "[promo] $*"; }
_promo_ok()  { echo "[OK]    $*"; }
_promo_warn(){ echo "[WARN]  $*"; }
_promo_err() { echo "[ERROR] $*" >&2; }

# =============================================================================
# create_app_version
#
# Creates the AppTrust application version. Idempotent: 409 = already exists.
# =============================================================================
create_app_version() {
  local _JPD="${JPD_URL%/}"

  : "${_JPD:?JPD_URL is required}"
  : "${JF_ADMIN_TOKEN:?JF_ADMIN_TOKEN is required}"
  : "${APPLICATION_KEY:?APPLICATION_KEY is required}"
  : "${APP_VERSION:?APP_VERSION is required}"
  : "${PROJECT_KEY:?PROJECT_KEY is required}"

  _promo_log "Creating ${APPLICATION_KEY}@${APP_VERSION} in AppTrust..."

  local payload
  payload=$(jq -n --arg v "${APP_VERSION}" '{"version": $v, "sources": {}}')

  local response_body http_status
  response_body="$(mktemp /tmp/create_version_XXXXXX.json)"

  http_status=$(curl --silent --output "${response_body}" --write-out "%{http_code}" \
    --request POST \
    --url "${_JPD}/apptrust/api/v1/applications/${APPLICATION_KEY}/versions?async=false" \
    --header "Authorization: Bearer ${JF_ADMIN_TOKEN}" \
    --header "Content-Type: application/json" \
    --header "X-JFrog-Project: ${PROJECT_KEY}" \
    --data "${payload}")

  if [[ "${http_status}" == "201" ]]; then
    _promo_ok "Version ${APP_VERSION} created"
  elif [[ "${http_status}" == "409" ]]; then
    _promo_warn "Version ${APP_VERSION} already exists -- continuing"
  else
    _promo_err "create_app_version: unexpected HTTP ${http_status}"
    _promo_err "Response: $(cat "${response_body}")"
    rm -f "${response_body}"
    return 1
  fi

  rm -f "${response_body}"
}

# =============================================================================
# advance_to_stage
#
# Promotes the application version to the specified stage.
# async=false is MANDATORY -- do not change.
# Args: $1 = target_stage (e.g. "aigp-demo-DEV")
# =============================================================================
advance_to_stage() {
  local target_stage="$1"
  local _JPD="${JPD_URL%/}"

  : "${_JPD:?JPD_URL is required}"
  : "${JF_ADMIN_TOKEN:?JF_ADMIN_TOKEN is required}"
  : "${APPLICATION_KEY:?APPLICATION_KEY is required}"
  : "${APP_VERSION:?APP_VERSION is required}"

  _promo_log "Promoting ${APPLICATION_KEY}@${APP_VERSION} -> ${target_stage}..."

  local payload
  payload=$(jq -n \
    --arg stage "${target_stage}" \
    '{"target_stage": $stage, "promotion_type": "move"}')

  local response_body http_status
  response_body="$(mktemp /tmp/promo_response_XXXXXX.json)"

  http_status=$(curl --silent --output "${response_body}" --write-out "%{http_code}" \
    --request POST \
    --url "${_JPD}/apptrust/api/v1/applications/${APPLICATION_KEY}/versions/${APP_VERSION}/promote?async=false" \
    --header "Authorization: Bearer ${JF_ADMIN_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "${payload}")

  if [[ "${http_status}" == "200" ]]; then
    _promo_ok "Promoted to ${target_stage}"
  else
    _promo_err "advance_to_stage ${target_stage}: HTTP ${http_status}"
    _promo_err "Response: $(cat "${response_body}")"
    rm -f "${response_body}"
    return 1
  fi

  rm -f "${response_body}"
}

# =============================================================================
# get_current_stage
#
# Prints the current stage of the application version to stdout.
# =============================================================================
get_current_stage() {
  local _JPD="${JPD_URL%/}"

  : "${_JPD:?JPD_URL is required}"
  : "${JF_ADMIN_TOKEN:?JF_ADMIN_TOKEN is required}"
  : "${APPLICATION_KEY:?APPLICATION_KEY is required}"
  : "${APP_VERSION:?APP_VERSION is required}"

  curl --silent --fail \
    --url "${_JPD}/apptrust/api/v1/applications/${APPLICATION_KEY}/versions/${APP_VERSION}/content" \
    --header "Authorization: Bearer ${JF_ADMIN_TOKEN}" \
    --header "Content-Type: application/json" \
    | jq -r '.stage // "UNKNOWN"'
}

# =============================================================================
# wait_for_human_approval
#
# Polls AppTrust by attempting release on each tick. The QA exit gate
# (aigp-model-card + aigp-human-oversight-approval) must be satisfied
# before AppTrust will accept the release call.
#
# AIGP BoK: Domain I  — Human agency and oversight
# EU AI Act: Art. 14  — Human oversight measures
# Gate: QA exit (manual evidence required)
#
# Args:
#   $1 = timeout_minutes  (default: 30)
#   $2 = poll_interval_s  (default: 60)
# =============================================================================
wait_for_human_approval() {
  local timeout_minutes="${1:-30}"
  local poll_interval="${2:-60}"
  local max_polls=$(( timeout_minutes * 60 / poll_interval ))
  local _JPD="${JPD_URL%/}"
  local attempt=0

  : "${_JPD:?JPD_URL is required}"
  : "${JF_ADMIN_TOKEN:?JF_ADMIN_TOKEN is required}"
  : "${APPLICATION_KEY:?APPLICATION_KEY is required}"
  : "${APP_VERSION:?APP_VERSION is required}"

  _promo_log "ACTION REQUIRED: approve in AppTrust UI"
  _promo_log "  Open:  ${_JPD}/ui/apptrust/applications/${APPLICATION_KEY}"
  _promo_log "  Task:  attach aigp-human-oversight-approval evidence for v${APP_VERSION}"
  _promo_log "Polling every ${poll_interval}s (timeout: ${timeout_minutes}m)..."

  while [[ ${attempt} -lt ${max_polls} ]]; do
    attempt=$(( attempt + 1 ))
    _promo_log "Poll ${attempt}/${max_polls}: attempting release to PROD..."

    local response_body http_status
    response_body="$(mktemp /tmp/release_poll_XXXXXX.json)"

    http_status=$(curl --silent --output "${response_body}" --write-out "%{http_code}" \
      --request POST \
      --url "${_JPD}/apptrust/api/v1/applications/${APPLICATION_KEY}/versions/${APP_VERSION}/release?async=false" \
      --header "Authorization: Bearer ${JF_ADMIN_TOKEN}" \
      --header "Content-Type: application/json")

    rm -f "${response_body}"

    if [[ "${http_status}" == "200" ]]; then
      _promo_ok "Human approval confirmed -- released to PROD"
      return 0
    fi

    _promo_log "Gate not satisfied (HTTP ${http_status}) -- waiting ${poll_interval}s"

    if [[ ${attempt} -lt ${max_polls} ]]; then
      sleep "${poll_interval}"
    fi
  done

  _promo_err "Timed out after ${timeout_minutes} minutes waiting for human approval"
  return 1
}
