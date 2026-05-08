#!/usr/bin/env bash
# =============================================================================
# evidence/evidence-lib.sh — Evidence generation and attachment library
#
# AIGP BoK: Domain III — Cryptographic provenance, data lineage, TEVV process
# AIGP BoK: Domain IV  — AI impact assessment, continuous monitoring
# EU AI Act: Art. 9, 10, 12, 13, 14 — Risk mgmt, data governance, records
#
# Usage: Source this file — do not execute directly
#   source evidence/evidence-lib.sh
#
# Required env vars (injected by CI job env block):
#   APPLICATION_KEY        — e.g. aigp-devops-helper-llm
#   APP_VERSION            — e.g. 2.1.5
#   EVIDENCE_PRIVATE_KEY   — raw PEM content (GitHub secret)
#   EVIDENCE_KEY_ALIAS     — e.g. aigp-Evidence-Key
#   TEMPLATES_DIR          — path to evidence/templates/
#   MODEL_CARD_PATH        — path to models/devops-helper/model_card.json
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "[ERROR] evidence-lib.sh must be sourced, not executed directly"
  exit 1
fi

_evd_log() { echo "[evd]   $*"; }
_evd_ok()  { echo "[OK]    $*"; }
_evd_warn(){ echo "[WARN]  $*"; }
_evd_err() { echo "[ERROR] $*" >&2; }

# =============================================================================
# generate_random_values
#
# Exports variables used by envsubst in JSON templates.
# All fake evidence follows the $RANDOM pattern from BookVerse reference.
# =============================================================================
generate_random_values() {
  export ASSESSMENT_ID
  ASSESSMENT_ID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  ASSESSMENT_ID="${ASSESSMENT_ID,,}"

  export TEST_SUITE_ID
  TEST_SUITE_ID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  TEST_SUITE_ID="${TEST_SUITE_ID,,}"

  export RUN_ID="${GITHUB_RUN_ID:-local-$(date +%s)}"
  export TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  export ASSESSOR="aigp-pipeline@${APPLICATION_KEY}"

  # Impact assessment fields
  export RISK_LEVEL="LOW"
  export RISK_SCORE="0$(echo "scale=2; $(shuf -i 10-35 -n1)/100" | bc)"

  # TEVV bias test fields
  export TOTAL_TESTS=$((20 + RANDOM % 30))
  export PASSED_TESTS=$((TOTAL_TESTS - RANDOM % 3))
  export FAILED_TESTS=$((TOTAL_TESTS - PASSED_TESTS))
  export BIAS_SCORE="0$(echo "scale=3; $(shuf -i 950-999 -n1)/1000" | bc)"

  _evd_log "Random values: ASSESSMENT_ID=${ASSESSMENT_ID} TOTAL_TESTS=${TOTAL_TESTS} BIAS_SCORE=${BIAS_SCORE}"
}

# =============================================================================
# process_template
#
# Substitutes env vars into a JSON template via envsubst.
# Args: $1 = template file, $2 = output file
# =============================================================================
process_template() {
  local template_file="$1"
  local output_file="$2"

  if [[ ! -f "${template_file}" ]]; then
    _evd_err "Template not found: ${template_file}"
    return 1
  fi

  envsubst < "${template_file}" > "${output_file}"
  _evd_log "Processed template: ${template_file}"
}

# =============================================================================
# evd_create
#
# Attaches a signed evidence attestation to an AppTrust application version.
# EVIDENCE_PRIVATE_KEY is passed as raw PEM content directly to --key.
#
# Args:
#   $1 = predicate_file  — path to evidence JSON payload
#   $2 = predicate_type  — URI e.g. https://aigp.iapp.org/evidence/tevv/v1
#   $3 = markdown_file   — path to .md summary
#   $4 = evidence_label  — short name for logging
# =============================================================================
evd_create() {
  local predicate_file="$1"
  local predicate_type="$2"
  local markdown_file="$3"
  local evidence_label="${4:-evidence}"

  : "${APPLICATION_KEY:?APPLICATION_KEY is required}"
  : "${APP_VERSION:?APP_VERSION is required}"
  : "${EVIDENCE_PRIVATE_KEY:?EVIDENCE_PRIVATE_KEY is required}"
  : "${EVIDENCE_KEY_ALIAS:?EVIDENCE_KEY_ALIAS is required}"

  _evd_log "Attaching ${evidence_label} evidence..."

  jf evd create-evidence \
    --predicate      "${predicate_file}" \
    --markdown       "${markdown_file}" \
    --predicate-type "${predicate_type}" \
    --application-key     "${APPLICATION_KEY}" \
    --application-version "${APP_VERSION}" \
    --provider-id    github-actions \
    --key            "${EVIDENCE_PRIVATE_KEY}" \
    --key-alias      "${EVIDENCE_KEY_ALIAS}"

  local exit_code=$?
  if [[ ${exit_code} -eq 0 ]]; then
    _evd_ok "${evidence_label} evidence attached"
  else
    _evd_err "${evidence_label} evidence failed (exit ${exit_code})"
    return ${exit_code}
  fi
}

# =============================================================================
# attach_impact_assessment_evidence
#
# FAKE evidence — random approval ID, deterministic risk level.
# AIGP BoK: Domain IV — Perform AI Impact Assessment
# EU AI Act: Art. 9   — Risk management system
# Gate: UNASSIGNED exit
# =============================================================================
attach_impact_assessment_evidence() {
  _evd_log "--- Impact Assessment (UNASSIGNED exit) ---"

  generate_random_values

  local predicate_file markdown_file
  predicate_file="$(mktemp /tmp/impact_assessment_XXXXXX.json)"
  markdown_file="$(mktemp /tmp/impact_assessment_XXXXXX.md)"

  process_template "${TEMPLATES_DIR}/impact_assessment.json.template" "${predicate_file}"

  cat > "${markdown_file}" <<MDEOF
## AIGP Impact Assessment

| Field | Value |
|---|---|
| Assessment ID | ${ASSESSMENT_ID} |
| Model | ${APPLICATION_KEY} v${APP_VERSION} |
| Risk Level | ${RISK_LEVEL} |
| Risk Score | ${RISK_SCORE} |
| Assessor | ${ASSESSOR} |
| Timestamp | ${TIMESTAMP} |

**Compliance:** EU AI Act Art. 9 -- Risk Management System
**AIGP BoK:** Domain IV -- Perform AI Impact Assessment
**NIST AI RMF:** GOVERN function
MDEOF

  evd_create \
    "${predicate_file}" \
    "https://aigp.iapp.org/evidence/impact-assessment/v1" \
    "${markdown_file}" \
    "aigp-impact-assessment"

  rm -f "${predicate_file}" "${markdown_file}"
}

# =============================================================================
# attach_tevv_bias_test_evidence
#
# FAKE evidence — IBM Fairlearn format, random pass/fail counts.
# AIGP BoK: Domain III — Use TEVV process for testing and evaluation
# EU AI Act: Art. 9    — Testing procedures during development
# Gate: DEV exit
# =============================================================================
attach_tevv_bias_test_evidence() {
  _evd_log "--- TEVV Bias Test (DEV exit) ---"

  generate_random_values

  local predicate_file markdown_file
  predicate_file="$(mktemp /tmp/tevv_bias_test_XXXXXX.json)"
  markdown_file="$(mktemp /tmp/tevv_bias_test_XXXXXX.md)"

  process_template "${TEMPLATES_DIR}/tevv_bias_test.json.template" "${predicate_file}"

  cat > "${markdown_file}" <<MDEOF
## AIGP TEVV Bias Test Report

| Field | Value |
|---|---|
| Test Suite ID | ${TEST_SUITE_ID} |
| Model | ${APPLICATION_KEY} v${APP_VERSION} |
| Total Tests | ${TOTAL_TESTS} |
| Passed | ${PASSED_TESTS} |
| Failed | ${FAILED_TESTS} |
| Bias Score | ${BIAS_SCORE} |
| Timestamp | ${TIMESTAMP} |

**Compliance:** EU AI Act Art. 9 -- Testing procedures during development
**AIGP BoK:** Domain III -- Use TEVV process
**NIST AI RMF:** MEASURE function
MDEOF

  evd_create \
    "${predicate_file}" \
    "https://aigp.iapp.org/evidence/tevv/v1" \
    "${markdown_file}" \
    "aigp-tevv-bias-test"

  rm -f "${predicate_file}" "${markdown_file}"
}

# =============================================================================
# attach_model_card_evidence
#
# REAL evidence — reads the actual model_card.json committed to the repo.
# AIGP BoK: Domain III — Complete model cards and fact sheets
# EU AI Act: Art. 13   — Transparency and provision of information
# Gate: QA exit
# =============================================================================
attach_model_card_evidence() {
  _evd_log "--- Model Card (QA exit) ---"

  : "${MODEL_CARD_PATH:?MODEL_CARD_PATH is required}"

  if [[ ! -f "${MODEL_CARD_PATH}" ]]; then
    _evd_err "Model card not found: ${MODEL_CARD_PATH}"
    return 1
  fi

  local markdown_file
  markdown_file="$(mktemp /tmp/model_card_XXXXXX.md)"

  cat > "${markdown_file}" <<MDEOF
## AIGP Model Card

Model card: \`${MODEL_CARD_PATH}\`
Application: ${APPLICATION_KEY} v${APP_VERSION}

**Compliance:** EU AI Act Art. 13 -- Transparency and provision of information
**AIGP BoK:** Domain III -- Complete model cards and fact sheets
**NIST AI RMF:** MEASURE function
MDEOF

  evd_create \
    "${MODEL_CARD_PATH}" \
    "https://aigp.iapp.org/evidence/model-card/v1" \
    "${markdown_file}" \
    "aigp-model-card"

  rm -f "${markdown_file}"
}

# =============================================================================
# attach_human_oversight_evidence
#
# MANUAL evidence — approver identity, timestamp, approval decision.
# Called by 02_approve.yml when the designated human approver triggers
# the approval workflow after reviewing the evidence in AppTrust.
#
# AIGP BoK: Domain I   — Human agency and oversight
# EU AI Act: Art. 14   — Human oversight measures
# Gate: QA exit (released to PROD only after this evidence is attached)
# =============================================================================
attach_human_oversight_evidence() {
  _evd_log "--- Human Oversight Approval (QA exit) ---"

  : "${APPLICATION_KEY:?APPLICATION_KEY is required}"
  : "${APP_VERSION:?APP_VERSION is required}"

  local predicate_file markdown_file timestamp
  predicate_file="$(mktemp /tmp/human_oversight_XXXXXX.json)"
  markdown_file="$(mktemp /tmp/human_oversight_XXXXXX.md)"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq -n \
    --arg approver "elia@jfrog.com" \
    --arg ts        "${timestamp}" \
    --arg app       "${APPLICATION_KEY}" \
    --arg ver       "${APP_VERSION}" \
    '{
      "approver":    $approver,
      "approved":    true,
      "timestamp":   $ts,
      "comment":     "Human oversight review completed - approved for PROD",
      "application": $app,
      "version":     $ver
    }' > "${predicate_file}"

  cat > "${markdown_file}" <<MDEOF
## AIGP Human Oversight Approval

| Field | Value |
|---|---|
| Approver | elia@jfrog.com |
| Application | ${APPLICATION_KEY} v${APP_VERSION} |
| Decision | Approved for PROD |
| Timestamp | ${timestamp} |

**Compliance:** EU AI Act Art. 14 -- Human oversight measures
**AIGP BoK:** Domain I -- Human agency and oversight
**NIST AI RMF:** GOVERN function
MDEOF

  evd_create \
    "${predicate_file}" \
    "https://aigp.iapp.org/evidence/human-oversight/v1" \
    "${markdown_file}" \
    "aigp-human-oversight-approval"

  rm -f "${predicate_file}" "${markdown_file}"
}

# =============================================================================
# attach_evidence_for_stage
#
# Routes evidence attachment based on the current pipeline stage.
# Args: $1 = stage name ("UNASSIGNED", "DEV", "QA")
# =============================================================================
attach_evidence_for_stage() {
  local stage="$1"

  case "${stage}" in
    UNASSIGNED) attach_impact_assessment_evidence ;;
    DEV)        attach_tevv_bias_test_evidence     ;;
    QA)         attach_model_card_evidence         ;;
    *)
      _evd_err "Unknown stage: ${stage}"
      return 1
      ;;
  esac
}
