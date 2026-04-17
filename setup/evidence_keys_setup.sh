#!/usr/bin/env bash
# =============================================================================
# evidence_keys_setup.sh — Generate & register evidence signing keys
#
# AIGP BoK: Domain III — Cryptographic provenance creates non-repudiable evidence
# EU AI Act: Art. 12 — Record-keeping must use tamper-evident mechanisms
#
# Usage:
#   source setup/config.env && bash setup/evidence_keys_setup.sh
#
# Required env vars:
#   JPD_URL            — e.g. https://tsmemea.jfrog.io
#   JF_ADMIN_TOKEN     — Admin identity token (manage permissions required)
#   EVIDENCE_KEY_ALIAS — e.g. aigp-Evidence-Key
#   GITHUB_REPO        — e.g. eliajfrog/aigp-mlops-hub
# =============================================================================
set -euo pipefail
# Ensure script is executable
# Run: chmod +x setup/evidence_keys_setup.sh

# --- Validate required env vars ----------------------------------------------
: "${JPD_URL:?JPD_URL is required}"
: "${JF_ADMIN_TOKEN:?JF_ADMIN_TOKEN is required}"
: "${EVIDENCE_KEY_ALIAS:?EVIDENCE_KEY_ALIAS is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required}"

PRIVATE_KEY_FILE="$(mktemp /tmp/evidence_private_XXXXXX.pem)"
PUBLIC_KEY_FILE="$(mktemp /tmp/evidence_public_XXXXXX.pem)"

echo "aigp-mlops-hub -- Evidence Key Setup"
echo "   JPD:       ${JPD_URL}"
echo "   Key alias: ${EVIDENCE_KEY_ALIAS}"
echo "   Repo:      ${GITHUB_REPO}"
echo ""

# =============================================================================
# STEP 1 -- Generate RSA 2048 key pair
# AIGP: Domain III — Strong key material underpins cryptographic provenance
# EU AI Act: Art. 12 — Audit trail integrity requires asymmetric signing
# =============================================================================
echo "Step 1/5 -- Generating RSA 2048 key pair..."

openssl genrsa -out "${PRIVATE_KEY_FILE}" 2048 2>/dev/null
openssl rsa -in "${PRIVATE_KEY_FILE}" -pubout -out "${PUBLIC_KEY_FILE}" 2>/dev/null

echo "[ OK ] Key pair generated (temp files, will be deleted in Step 5)"

# =============================================================================
# STEP 2 -- Upload public key to JFrog trusted keys
# AIGP: Domain III — Platform-registered keys allow AppTrust to verify evidence
# EU AI Act: Art. 12 — Verifiable signatures require a trusted key registry
# =============================================================================
echo ""
echo "Step 2/5 -- Uploading public key to JFrog trusted keys..."

PUBLIC_KEY_CONTENT="$(cat "${PUBLIC_KEY_FILE}")"

PAYLOAD=$(jq -n \
  --arg alias "${EVIDENCE_KEY_ALIAS}" \
  --arg key "${PUBLIC_KEY_CONTENT}" \
  '{"alias": $alias, "public_key": $key}')

HTTP_STATUS=$(curl --silent --output /dev/null --write-out "%{http_code}" \
  --request POST \
  --url "${JPD_URL}/artifactory/api/security/keys/trusted" \
  --header "Authorization: Bearer ${JF_ADMIN_TOKEN}" \
  --header "Content-Type: application/json" \
  --data "${PAYLOAD}")

if [ "${HTTP_STATUS}" = "201" ]; then
  echo "[ OK ] Public key registered in JFrog trusted keys (alias: ${EVIDENCE_KEY_ALIAS})"
elif [ "${HTTP_STATUS}" = "409" ]; then
  echo "[ WARN ] Key alias '${EVIDENCE_KEY_ALIAS}' already exists in JFrog -- skipping upload, continuing"
else
  echo "[ ERROR ] Unexpected HTTP status ${HTTP_STATUS} from JFrog trusted keys API"
  exit 1
fi

# =============================================================================
# STEP 3 -- Set EVIDENCE_PRIVATE_KEY as GitHub repo secret
# AIGP: Domain IV — Secrets management is part of secure-by-design pipelines
# EU AI Act: Art. 9 — Risk management includes protecting signing credentials
# =============================================================================
echo ""
echo "Step 3/5 -- Setting EVIDENCE_PRIVATE_KEY GitHub secret..."

gh secret set EVIDENCE_PRIVATE_KEY \
  --repo "${GITHUB_REPO}" \
  --body "$(cat "${PRIVATE_KEY_FILE}")"

echo "[ OK ] EVIDENCE_PRIVATE_KEY set as GitHub repo secret"

# =============================================================================
# STEP 4 -- Set EVIDENCE_KEY_ALIAS as GitHub repo variable
# AIGP: Domain III — Key alias is non-secret; stored as variable for pipeline use
# EU AI Act: Art. 12 — Evidence verification requires the alias to be known to CI
# =============================================================================
echo ""
echo "Step 4/5 -- Setting EVIDENCE_KEY_ALIAS GitHub variable..."

gh variable set EVIDENCE_KEY_ALIAS \
  --repo "${GITHUB_REPO}" \
  --body "${EVIDENCE_KEY_ALIAS}"

echo "[ OK ] EVIDENCE_KEY_ALIAS set as GitHub repo variable"

# =============================================================================
# STEP 5 -- Delete local key files
# AIGP: Domain IV — Secure disposal of key material limits exposure window
# EU AI Act: Art. 9 — Risk management requires minimising credential residency
# =============================================================================
echo ""
echo "Step 5/5 -- Deleting local key files..."

rm -f "${PRIVATE_KEY_FILE}" "${PUBLIC_KEY_FILE}"

echo "[ OK ] Local key files deleted"

# =============================================================================
echo ""
echo "Evidence key setup complete."
echo "   Public key registered in JFrog (alias: ${EVIDENCE_KEY_ALIAS})"
echo "   Private key stored in GitHub secret EVIDENCE_PRIVATE_KEY"
echo "   GitHub variable EVIDENCE_KEY_ALIAS set"
echo "   No key material remains on disk"
echo ""
echo "Next step: run setup/00_platform_setup.sh"
