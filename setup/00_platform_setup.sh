#!/usr/bin/env bash
# =============================================================================
# 00_platform_setup.sh — One-time JFrog platform provisioning for aigp-mlops-hub
#
# Creates all infrastructure required for the AIGP governance pipeline.
# Idempotent — safe to re-run without breaking existing resources.
#
# AIGP BoK: Domain III + IV — Supply chain traceability + Conformity assessment
# EU AI Act: Art. 9, 10, 12, 13, 14, 15
#
# Usage:
#   set -a; source <(grep -v '^#' setup/config.env | grep -v '^$' | sed 's/ #.*//'); set +a
#   bash setup/00_platform_setup.sh
# =============================================================================
set -euo pipefail
# Ensure script is executable
# Run: chmod +x setup/00_platform_setup.sh

# =============================================================================
# Validate required env vars
# =============================================================================
: "${JPD_URL:?JPD_URL is required — source setup/config.env first}"
: "${JF_ADMIN_TOKEN:?JF_ADMIN_TOKEN is required}"
: "${PROJECT_KEY:?PROJECT_KEY is required}"
: "${APPLICATION_KEY:?APPLICATION_KEY is required}"
: "${STAGE_DEV:?STAGE_DEV is required}"
: "${STAGE_QA:?STAGE_QA is required}"
: "${STAGE_PROD:?STAGE_PROD is required}"
: "${DOCKER_LOCAL_REPO:?DOCKER_LOCAL_REPO is required}"
: "${DOCKER_REMOTE_REPO:?DOCKER_REMOTE_REPO is required}"
: "${DOCKER_VIRTUAL_REPO:?DOCKER_VIRTUAL_REPO is required}"
: "${XRAY_POLICY_NAME:?XRAY_POLICY_NAME is required}"
: "${XRAY_WATCH_NAME:?XRAY_WATCH_NAME is required}"

# Strip trailing slash once — used throughout
JPD="${JPD_URL%/}"

# =============================================================================
# Logging helpers (pattern from BookVerse common.sh, adapted — no emojis)
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

FAILED=false

log_info()    { echo -e "${BLUE}[INFO]   $1${NC}"; }
log_success() { echo -e "${GREEN}[OK]     $1${NC}"; }
log_warning() { echo -e "${YELLOW}[WARN]   $1${NC}"; }
log_error()   { echo -e "${RED}[ERROR]  $1${NC}"; FAILED=true; }
log_step()    { echo -e "${CYAN}[STEP]   $1${NC}"; }

log_section() {
  echo ""
  echo -e "${YELLOW}=== $1 ===${NC}"
  echo ""
}

error_handler() {
  local line_no=$1
  local error_code=$2
  echo ""
  echo -e "${RED}[ERROR] Script failed at line $line_no (exit code: $error_code)${NC}"
  echo "        Command: ${BASH_COMMAND}"
  echo "        JPD:     ${JPD}"
  echo "        Project: ${PROJECT_KEY}"
  echo ""
  exit "$error_code"
}
trap 'error_handler ${LINENO} $?' ERR

# =============================================================================
# API helper — adapted from BookVerse jfrog_api_call()
# Uses JF_ADMIN_TOKEN (our var name, not JFROG_ADMIN_TOKEN)
# Returns HTTP status code; writes body to output_file if provided
# =============================================================================
jfrog_api_call() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local output_file="${4:-/dev/null}"
  local tmp
  tmp=$(mktemp)

  local curl_args=(
    -s
    -w "%{http_code}"
    -o "$tmp"
    --header "Authorization: Bearer ${JF_ADMIN_TOKEN}"
    --header "Content-Type: application/json"
    -X "$method"
  )
  [[ -n "$data" ]] && curl_args+=(-d "$data")

  local code
  code=$(curl "${curl_args[@]}" "$url")
  [[ "$output_file" != "/dev/null" ]] && cp "$tmp" "$output_file"
  rm -f "$tmp"
  echo "$code"
}

# handle_api_response — adapted from BookVerse common.sh
# 400 is treated as error here; repo creation handles it separately
handle_api_response() {
  local code="$1"
  local name="$2"
  local op="${3:-operation}"
  case "$code" in
    200|201|202|204)
      log_success "$name $op (HTTP $code)"
      return 0 ;;
    409)
      log_warning "$name already exists (HTTP $code) -- skipping"
      return 0 ;;
    401)
      log_error "$name $op failed -- unauthorized (HTTP $code)"
      return 1 ;;
    404)
      log_error "$name $op failed -- not found (HTTP $code)"
      return 1 ;;
    *)
      log_error "$name $op failed (HTTP $code)"
      return 1 ;;
  esac
}

# =============================================================================
# Banner
# =============================================================================
echo ""
echo "aigp-mlops-hub -- Platform Setup"
echo "   JPD:     ${JPD}"
echo "   Project: ${PROJECT_KEY}"
echo ""

# =============================================================================
# SECTION 1 -- JFrog Project
# AIGP: Domain IV — Project is the governance container for all AppTrust resources
# EU AI Act: Art. 9 — Risk management system requires an organizational scope
# =============================================================================
log_section "Section 1/7 -- JFrog Project"

log_step "Checking if project '${PROJECT_KEY}' exists..."
PROJECT_CHECK_CODE=$(jfrog_api_call GET "${JPD}/access/api/v1/projects/${PROJECT_KEY}")

if [[ "$PROJECT_CHECK_CODE" == "200" ]]; then
  log_warning "Project '${PROJECT_KEY}' already exists -- skipping"
else
  log_step "Creating project: ${PROJECT_KEY}"
  PROJECT_PAYLOAD=$(jq -n \
    --arg key "${PROJECT_KEY}" \
    '{"project_key": $key,
      "display_name": "AIGP Demo",
      "description": "AIGP/NIST AI RMF/EU AI Act compliance demo project",
      "admin_privileges": {
        "manage_members": true,
        "manage_resources": true,
        "index_resources": true
      }}')

  PROJECT_CODE=$(jfrog_api_call POST \
    "${JPD}/access/api/v1/projects" "$PROJECT_PAYLOAD")
  handle_api_response "$PROJECT_CODE" "Project '${PROJECT_KEY}'" "creation" || FAILED=true
fi

# =============================================================================
# SECTION 2 -- Docker Repositories
# AIGP: Domain III — Supply chain traceability requires governed artifact storage
# EU AI Act: Art. 10 — Data governance boundaries enforced via segregated repos
# =============================================================================
log_section "Section 2/7 -- Docker Repositories"

create_repo() {
  local repo_key="$1"
  local payload="$2"

  # Always POST — creates if missing, updates if exists (applies xrayIndex on re-run)
  local code
  code=$(jfrog_api_call POST \
    "${JPD}/artifactory/api/repositories/${repo_key}?project=${PROJECT_KEY}" "$payload")
  case "$code" in
    200|201)
      log_success "Repo '${repo_key}' created/updated (HTTP $code)" ;;
    409)
      log_warning "Repo '${repo_key}' already exists (HTTP $code) -- skipping" ;;
    *)
      log_error "Repo '${repo_key}' create/update failed (HTTP $code)"
      FAILED=true ;;
  esac
}

# Local repo — all model and container artifacts land here
create_repo "${DOCKER_LOCAL_REPO}" "$(jq -n \
  '{"rclass": "local", "packageType": "docker",
    "dockerApiVersion": "V2", "xrayIndex": "true"}')"

# Remote repo — proxies Docker Hub, all pulls are logged
create_repo "${DOCKER_REMOTE_REPO}" "$(jq -n \
  '{"rclass": "remote", "packageType": "docker",
    "url": "https://registry-1.docker.io", "xrayIndex": "true"}')"

# Virtual repo — single pull address, routes to local then remote
create_repo "${DOCKER_VIRTUAL_REPO}" "$(jq -n \
  --arg local_repo "${DOCKER_LOCAL_REPO}" \
  --arg remote_repo "${DOCKER_REMOTE_REPO}" \
  --arg deploy "${DOCKER_LOCAL_REPO}" \
  '{"rclass": "virtual", "packageType": "docker",
    "repositories": [$local_repo, $remote_repo],
    "defaultDeploymentRepo": $deploy}')"

# Assign repos to project (idempotent — 2xx whether already assigned or not)
assign_repo_to_project() {
  local repo_key="$1"
  log_step "Assigning repo '${repo_key}' to project '${PROJECT_KEY}'"
  local payload
  payload=$(jq -n --arg proj "${PROJECT_KEY}" '{"projectKey": $proj}')
  local code
  code=$(jfrog_api_call POST \
    "${JPD}/artifactory/api/repositories/${repo_key}" "$payload")
  case "$code" in
    200|201|204)
      log_success "Repo '${repo_key}' assigned to project '${PROJECT_KEY}' (HTTP $code)" ;;
    409)
      log_warning "Repo '${repo_key}' already assigned to project (HTTP $code)" ;;
    *)
      log_error "Repo '${repo_key}' project assignment failed (HTTP $code)"
      FAILED=true ;;
  esac
}

assign_repo_to_project "${DOCKER_LOCAL_REPO}"
assign_repo_to_project "${DOCKER_REMOTE_REPO}"
assign_repo_to_project "${DOCKER_VIRTUAL_REPO}"

# Per-stage local Docker repos — one per lifecycle stage for stage-scoped
# artifact storage (AIGP Domain IV evidence traceability requirement)
DOCKER_DEV_LOCAL_REPO="aigp-demo-docker-dev-local"
DOCKER_QA_LOCAL_REPO="aigp-demo-docker-qa-local"
DOCKER_PROD_LOCAL_REPO="aigp-demo-docker-prod-local"

create_repo "${DOCKER_DEV_LOCAL_REPO}" "$(jq -n \
  '{"rclass": "local", "packageType": "docker",
    "dockerApiVersion": "V2", "xrayIndex": "true"}')"

create_repo "${DOCKER_QA_LOCAL_REPO}" "$(jq -n \
  '{"rclass": "local", "packageType": "docker",
    "dockerApiVersion": "V2", "xrayIndex": "true"}')"

create_repo "${DOCKER_PROD_LOCAL_REPO}" "$(jq -n \
  '{"rclass": "local", "packageType": "docker",
    "dockerApiVersion": "V2", "xrayIndex": "true"}')"

# Assign each stage repo to its corresponding lifecycle stage
assign_repo_to_stage() {
  local repo_key="$1"
  local stage_name="$2"
  log_step "Assigning repo '${repo_key}' to stage '${stage_name}'"
  local payload
  payload=$(jq -n --arg stage "${stage_name}" '{"stages": [$stage]}')
  local code
  code=$(jfrog_api_call POST \
    "${JPD}/artifactory/api/repositories/${repo_key}" "$payload")
  handle_api_response "$code" "Repo '${repo_key}' stage assignment" "to '${stage_name}'" || FAILED=true
}

assign_repo_to_stage "${DOCKER_DEV_LOCAL_REPO}"  "${STAGE_DEV}"
assign_repo_to_stage "${DOCKER_QA_LOCAL_REPO}"   "${STAGE_QA}"
assign_repo_to_stage "${DOCKER_PROD_LOCAL_REPO}" "${STAGE_PROD}"

# =============================================================================
# SECTION 3 -- Lifecycle Stages
# AIGP: Domain IV — Conformity assessment requires defined promotion stages
# EU AI Act: Art. 9 — Risk management system requires gated lifecycle stages
# =============================================================================
log_section "Section 3/7 -- Lifecycle Stages"

create_stage() {
  local stage_name="$1"
  log_step "Creating stage: ${stage_name}"

  # Payload pattern from BookVerse create_stages.sh / build_stage_payload()
  local payload
  payload=$(jq -n \
    --arg name "${stage_name}" \
    --arg proj "${PROJECT_KEY}" \
    '{"name": $name, "scope": "project", "project_key": $proj, "category": "promote"}')

  local code
  code=$(jfrog_api_call POST "${JPD}/access/api/v2/stages/" "$payload")
  handle_api_response "$code" "Stage '${stage_name}'" "creation" || FAILED=true
}

# PROD and UNASSIGNED are system-managed — create DEV and QA only
create_stage "${STAGE_DEV}"
create_stage "${STAGE_QA}"

# Update lifecycle order — pattern from BookVerse create_lifecycle_configuration()
log_step "Setting lifecycle order: ${STAGE_DEV} -> ${STAGE_QA} -> PROD"
LIFECYCLE_PAYLOAD=$(jq -n \
  --arg dev "${STAGE_DEV}" \
  --arg qa "${STAGE_QA}" \
  --arg proj "${PROJECT_KEY}" \
  '{"promote_stages": [$dev, $qa], "project_key": $proj}')

LC_CODE=$(jfrog_api_call PATCH \
  "${JPD}/access/api/v2/lifecycle/?project_key=${PROJECT_KEY}" \
  "$LIFECYCLE_PAYLOAD")
handle_api_response "$LC_CODE" "Lifecycle order" "update" || FAILED=true

# =============================================================================
# SECTION 4 -- Unified Policy Rules
# AIGP: Domain III — Evidence-based governance requires defined rule predicates
# EU AI Act: Art. 9, 13, 14, 15 — Each rule maps to a specific compliance article
# =============================================================================
log_section "Section 4/7 -- Unified Policy Rules"

# create_or_update_rule — pattern from BookVerse create_rules.sh
# GET rules, find by name, PUT if exists / POST if not
create_or_update_rule() {
  local name="$1"
  local description="$2"
  local predicate_type="$3"
  local template_id="${4:-1003}"

  local rules_tmp
  rules_tmp=$(mktemp)
  jfrog_api_call GET "${JPD}/unifiedpolicy/api/v1/rules" "" "$rules_tmp" > /dev/null

  local existing_id
  existing_id=$(jq -r --arg n "$name" \
    '.items[] | select(.name == $n) | .id' "$rules_tmp" | head -1)
  rm -f "$rules_tmp"

  local payload
  payload=$(jq -n \
    --arg name "$name" \
    --arg desc "$description" \
    --arg pred "$predicate_type" \
    --arg tmpl "$template_id" \
    '{"name": $name, "description": $desc, "is_custom": true,
      "parameters": [{"name": "predicateType", "value": $pred}],
      "template_id": $tmpl}')

  if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
    log_info "Rule '${name}' exists -- updating (ID: ${existing_id})"
    local code
    code=$(jfrog_api_call PUT \
      "${JPD}/unifiedpolicy/api/v1/rules/${existing_id}" "$payload")
    handle_api_response "$code" "Rule '${name}'" "update" || FAILED=true
  else
    log_step "Creating rule: ${name}"
    local code
    code=$(jfrog_api_call POST \
      "${JPD}/unifiedpolicy/api/v1/rules" "$payload")
    handle_api_response "$code" "Rule '${name}'" "creation" || FAILED=true
  fi
}

# 4 custom evidence rules (template_id 1003)
# EU AI Act: Art. 9 — Risk management: Impact Assessment evidence
create_or_update_rule \
  "aigp-impact-assessment-rule" \
  "EU AI Act Art.9 / NIST Govern -- Impact Assessment evidence (UNASSIGNED exit)" \
  "https://aigp.iapp.org/evidence/impact-assessment/v1"

# EU AI Act: Art. 9 — Testing, evaluation, validation, and verification (TEVV)
create_or_update_rule \
  "aigp-tevv-bias-test-rule" \
  "EU AI Act Art.9 / NIST Measure -- TEVV bias test evidence (DEV exit)" \
  "https://aigp.iapp.org/evidence/tevv/v1"

# EU AI Act: Art. 13 — Transparency and model documentation
create_or_update_rule \
  "aigp-model-card-rule" \
  "EU AI Act Art.13 / NIST Measure -- Model Card evidence (QA exit)" \
  "https://aigp.iapp.org/evidence/model-card/v1"

# EU AI Act: Art. 14 — Human agency and oversight
create_or_update_rule \
  "aigp-human-oversight-approval-rule" \
  "EU AI Act Art.14 / NIST Govern -- Human oversight approval (QA exit)" \
  "https://aigp.iapp.org/evidence/human-oversight/v1"

# 2 gate-certify rules (template_id 1004) — PROD release gates
# EU AI Act: Art. 9 — Conformity assessment requires prior stage certification
create_or_update_rule \
  "aigp-dev-gate-certify-rule" \
  "PROD release requires DEV exit gate certification" \
  "https://jfrog.com/evidence/apptrust/gate-certify/v1" \
  "1004"

create_or_update_rule \
  "aigp-qa-gate-certify-rule" \
  "PROD release requires QA exit gate certification" \
  "https://jfrog.com/evidence/apptrust/gate-certify/v1" \
  "1004"

# Note: slsa-provenance and critical-cve-scan are JFrog built-in rules.
# Do NOT create them here — the platform enforces them natively.

# =============================================================================
# SECTION 5 -- Unified Policies
# AIGP: Domain IV — Policy gates enforce compliance at every lifecycle transition
# EU AI Act: Art. 9, 13, 14 — Gates map directly to conformity requirements
# =============================================================================
log_section "Section 5/7 -- Unified Policies"

# create_policy_if_missing — pattern from BookVerse create_policies.sh
# GET policies to skip if exists; resolve rule_id by name; POST policy
create_policy_if_missing() {
  local name="$1"
  local description="$2"
  local stage_key="$3"
  local gate="$4"
  local rule_name="$5"

  # Check if policy already exists
  local policies_tmp
  policies_tmp=$(mktemp)
  jfrog_api_call GET \
    "${JPD}/unifiedpolicy/api/v1/policies?projectKey=${PROJECT_KEY}" \
    "" "$policies_tmp" > /dev/null
  local existing_id
  existing_id=$(jq -r --arg n "$name" \
    '.items[] | select(.name == $n) | .id' "$policies_tmp" | head -1)
  rm -f "$policies_tmp"

  if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
    log_warning "Policy '${name}' already exists -- skipping"
    return 0
  fi

  # Resolve rule ID by name
  local rules_tmp
  rules_tmp=$(mktemp)
  jfrog_api_call GET "${JPD}/unifiedpolicy/api/v1/rules" "" "$rules_tmp" > /dev/null
  local rule_id
  rule_id=$(jq -r --arg n "$rule_name" \
    '.items[] | select(.name == $n) | .id' "$rules_tmp" | head -1)
  rm -f "$rules_tmp"

  if [[ -z "$rule_id" || "$rule_id" == "null" ]]; then
    log_error "Rule '${rule_name}' not found -- cannot create policy '${name}'"
    FAILED=true
    return 1
  fi

  log_step "Creating policy: ${name}"
  local payload
  payload=$(jq -n \
    --arg name "$name" \
    --arg desc "$description" \
    --arg gate "$gate" \
    --arg stage "$stage_key" \
    --arg rule_id "$rule_id" \
    --arg proj "${PROJECT_KEY}" \
    '{"name": $name, "description": $desc,
      "action": {"stage": {"gate": $gate, "key": $stage}, "type": "certify_to_gate"},
      "enabled": true, "mode": "warning",
      "rule_ids": [$rule_id],
      "scope": {"project_keys": [$proj], "type": "project"}}')

  local code
  code=$(jfrog_api_call POST "${JPD}/unifiedpolicy/api/v1/policies" "$payload")
  handle_api_response "$code" "Policy '${name}'" "creation" || FAILED=true
}

# EU AI Act: Art. 9 — Risk management: Impact Assessment required before DEV entry
create_policy_if_missing \
  "aigp-unassigned-exit-impact-assessment" \
  "EU AI Act Art.9 -- Impact Assessment required before DEV entry" \
  "${STAGE_DEV}" "entry" \
  "aigp-impact-assessment-rule"

# EU AI Act: Art. 9 — TEVV bias test required before QA entry
create_policy_if_missing \
  "aigp-dev-exit-tevv-bias-test" \
  "EU AI Act Art.9 -- TEVV bias test required before QA entry" \
  "${STAGE_QA}" "entry" \
  "aigp-tevv-bias-test-rule"

# EU AI Act: Art. 13 — Transparency: Model Card required before PROD
create_policy_if_missing \
  "aigp-qa-exit-model-card" \
  "EU AI Act Art.13 -- Model Card required before PROD" \
  "${STAGE_QA}" "exit" \
  "aigp-model-card-rule"

# EU AI Act: Art. 14 — Human oversight approval required before PROD
create_policy_if_missing \
  "aigp-qa-exit-human-oversight" \
  "EU AI Act Art.14 -- Human oversight approval required before PROD" \
  "${STAGE_QA}" "exit" \
  "aigp-human-oversight-approval-rule"

# PROD release gate: DEV exit must be certified
create_policy_if_missing \
  "aigp-prod-release-dev-cert" \
  "PROD release requires DEV exit gate certified" \
  "${STAGE_PROD}" "release" \
  "aigp-dev-gate-certify-rule"

# PROD release gate: QA exit must be certified
create_policy_if_missing \
  "aigp-prod-release-qa-cert" \
  "PROD release requires QA exit gate certified" \
  "${STAGE_PROD}" "release" \
  "aigp-qa-gate-certify-rule"

# =============================================================================
# SECTION 6 -- Xray Security Policy + Watch
# AIGP: Domain III — Continuous vulnerability scanning (TEVV)
# EU AI Act: Art. 15 — Cybersecurity requirements for high-risk AI systems
# =============================================================================
log_section "Section 6/7 -- Xray Security Policy + Watch"

log_step "Creating Xray security policy: ${XRAY_POLICY_NAME}"
XRAY_POLICY_PAYLOAD=$(jq -n \
  --arg name "${XRAY_POLICY_NAME}" \
  '{"name": $name,
    "description": "EU AI Act Art.15 -- Block critical CVEs from model promotion",
    "type": "security",
    "rules": [{
      "name": "block-critical-cves",
      "priority": 1,
      "criteria": {"min_severity": "critical"},
      "actions": {
        "block_release_bundle_distribution": true,
        "block_release_bundle_promotion": true,
        "fail_build": true
      }
    }]}')

XRAY_POLICY_CODE=$(jfrog_api_call POST \
  "${JPD}/xray/api/v2/policies" "$XRAY_POLICY_PAYLOAD")
handle_api_response "$XRAY_POLICY_CODE" \
  "Xray policy '${XRAY_POLICY_NAME}'" "creation" || FAILED=true

log_step "Creating Xray watch: ${XRAY_WATCH_NAME}"

WATCH_PAYLOAD=$(mktemp)
jq -n \
  --arg name "${XRAY_WATCH_NAME}" \
  --arg repo "${DOCKER_LOCAL_REPO}" \
  --arg policy "${XRAY_POLICY_NAME}" \
  '{
    "general_data": {
      "name": $name,
      "description": "Watch Docker repos for critical CVEs -- EU AI Act Art.15",
      "active": true
    },
    "project_resources": {
      "resources": [{
        "type": "repository",
        "bin_mgr_id": "default",
        "name": $repo
      }]
    },
    "assigned_policies": [{
      "name": $policy,
      "type": "security"
    }]
  }' > "$WATCH_PAYLOAD"

WATCH_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST \
  -H "Authorization: Bearer ${JF_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @"$WATCH_PAYLOAD" \
  "${JPD}/xray/api/v2/watches")

WATCH_HTTP=$(echo "$WATCH_RESPONSE" | tail -1)
WATCH_BODY=$(echo "$WATCH_RESPONSE" | head -1)
rm -f "$WATCH_PAYLOAD"

case "$WATCH_HTTP" in
  200|201)
    log_success "Xray watch '${XRAY_WATCH_NAME}' created (HTTP $WATCH_HTTP)"
    ;;
  409)
    log_warning "Xray watch '${XRAY_WATCH_NAME}' already exists -- skipping"
    ;;
  *)
    log_error "Xray watch '${XRAY_WATCH_NAME}' creation failed (HTTP $WATCH_HTTP)"
    log_error "Response: $WATCH_BODY"
    FAILED=true
    ;;
esac

log_step "Verifying Xray watch: ${XRAY_WATCH_NAME}"
VERIFY_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${JF_ADMIN_TOKEN}" \
  "${JPD}/xray/api/v2/watches/${XRAY_WATCH_NAME}")

if [[ "$VERIFY_CODE" == "200" ]]; then
  log_success "Xray watch '${XRAY_WATCH_NAME}' verified"
else
  log_error "Xray watch '${XRAY_WATCH_NAME}' not found (HTTP $VERIFY_CODE)"
  FAILED=true
fi

# =============================================================================
# SECTION 7 -- AppTrust Application
# AIGP: Domain IV — Conformity assessment requires a registered application entity
# EU AI Act: Art. 9 — Risk management system tied to a versioned, governed application
# =============================================================================
log_section "Section 7/7 -- AppTrust Application"

log_step "Creating AppTrust application: ${APPLICATION_KEY}"

APP_OUTPUT=$(jf apptrust app-create "${APPLICATION_KEY}" \
    --project "${PROJECT_KEY}" \
    --application-name "AIGP DevOps Helper LLM" \
    --desc "Governed AI model hub -- AIGP/NIST AI RMF/EU AI Act compliance. FastAPI pod + Qwen model through evidence-gated AppTrust pipeline." \
    --business-criticality "high" \
    --maturity-level "production" \
    --labels "team=aigp-demo;type=llm;framework=aigp-nist-euaiact" 2>&1) && {
  log_success "AppTrust application '${APPLICATION_KEY}' created"
} || {
  if echo "$APP_OUTPUT" | grep -qi "already exist\|conflict\|409"; then
    log_warning "AppTrust application '${APPLICATION_KEY}' already exists -- skipping"
  else
    log_error "AppTrust application '${APPLICATION_KEY}' creation failed: ${APP_OUTPUT}"
    FAILED=true
  fi
}

# Always update ownership — ensures owner is set correctly on every run
log_step "Setting owner on AppTrust application: ${APPLICATION_KEY}"
UPDATE_OUTPUT=$(jf apptrust app-update "${APPLICATION_KEY}" \
  --user-owners "elia@jfrog.com" 2>&1) && {
  log_success "AppTrust application '${APPLICATION_KEY}' owner set to elia@jfrog.com"
} || {
  log_warning "AppTrust application owner update failed (non-fatal): ${UPDATE_OUTPUT}"
}

# =============================================================================
# Final status
# =============================================================================
echo ""
if [[ "${FAILED}" == "true" ]]; then
  echo -e "${RED}[ERROR] Platform setup completed with failures.${NC}"
  echo "        Review errors above, fix the issue, and re-run."
  echo "        This script is idempotent -- safe to re-run."
  exit 1
else
  log_success "Platform setup complete."
  echo ""
  echo "   Docker repos:  ${DOCKER_LOCAL_REPO}, ${DOCKER_REMOTE_REPO}, ${DOCKER_VIRTUAL_REPO}"
  echo "   Stages:        ${STAGE_DEV}, ${STAGE_QA} (lifecycle order set)"
  echo "   Rules:         6 custom rules created/updated"
  echo "   Policies:      6 policies on correct gates"
  echo "   Xray policy:   ${XRAY_POLICY_NAME}"
  echo "   Xray watch:    ${XRAY_WATCH_NAME}"
  echo "   Application:   ${APPLICATION_KEY}"
  echo ""
fi
