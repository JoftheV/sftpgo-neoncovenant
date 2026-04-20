#!/usr/bin/env bash
# =============================================================================
# validate_api.sh — SFTPGo API regression test helper
# Called by GitHub Actions (validate.yml) and safe to run locally.
#
# Validates:
#   - Admin auth token acquisition
#   - Virtual folder existence and mapped path
#   - User quota_size, max_upload_file_size, virtual folder assignment
#   - User status (active)
#   - Virtual folder quota mirrors user quota
#
# Environment variables (injected by Actions secrets or local export):
#   ADMIN_PASS         — SFTPGo admin password
#   SFTPGO_USER_PASS   — SFTPGo user password (for user-token check)
#
# Hardcoded constants (must match sftpgo_setup.sh config):
#   SFTPGO_ADMIN_URL, ADMIN_USER, SFTPGO_USER, FOLDER_NAME, etc.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants — keep in sync with sftpgo_setup.sh
# ---------------------------------------------------------------------------
SFTPGO_ADMIN_URL="${SFTPGO_ADMIN_URL:-https://neoncovenant.appboxes.co}"
ADMIN_USER="${ADMIN_USER:-admin}"
SFTPGO_USER="${SFTPGO_USER:-jofthev}"
FOLDER_NAME="${FOLDER_NAME:-jofthev_data}"
FOLDER_LOCAL_PATH="${FOLDER_LOCAL_PATH:-/home/appbox/data/jofthev}"
FOLDER_VIRTUAL_PATH="${FOLDER_VIRTUAL_PATH:-/data}"
EXPECTED_QUOTA_SIZE="${EXPECTED_QUOTA_SIZE:-1073741824}"
EXPECTED_MAX_UPLOAD="${EXPECTED_MAX_UPLOAD:-1073741824}"

API="${SFTPGO_ADMIN_URL}/api/v2"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
pass()  { echo "  [PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()  { echo "  [FAIL] $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn()  { echo "  [WARN] $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
header(){ echo ""; echo "── $* ──────────────────────────────────────────"; }

# ---------------------------------------------------------------------------
# 1. Auth
# ---------------------------------------------------------------------------
header "Auth"

if [[ -z "${ADMIN_PASS:-}" ]]; then
  fail "ADMIN_PASS env var is not set. Export it or set the GitHub secret SFTPGO_ADMIN_PASS."
  exit 1
fi

RAW_AUTH=$(curl -sf --max-time 15 \
  -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "${API}/token" 2>&1) || true

TOKEN=$(echo "${RAW_AUTH}" | jq -r '.access_token // empty' 2>/dev/null || true)

if [[ -z "${TOKEN}" ]]; then
  fail "Admin auth failed — could not obtain JWT token"
  echo "  Response: ${RAW_AUTH}"
  exit 1
fi
pass "Admin JWT acquired"
AUTH="Authorization: Bearer ${TOKEN}"

# ---------------------------------------------------------------------------
# 2. Host reachability
# ---------------------------------------------------------------------------
header "Reachability"

VERSION_STATUS=$(curl -so /dev/null -w "%{http_code}" --max-time 10 "${API}/version" || echo "000")
if [[ "${VERSION_STATUS}" == "200" ]]; then
  pass "API version endpoint: HTTP ${VERSION_STATUS}"
else
  fail "API version endpoint returned HTTP ${VERSION_STATUS}"
fi

# ---------------------------------------------------------------------------
# 3. Virtual folder
# ---------------------------------------------------------------------------
header "Virtual Folder: ${FOLDER_NAME}"

FOLDER_JSON=$(curl -sf --max-time 15 \
  -H "${AUTH}" \
  "${API}/folders/${FOLDER_NAME}" 2>/dev/null || echo "{}")

FOLDER_NAME_RETURNED=$(echo "${FOLDER_JSON}" | jq -r '.name // empty')
if [[ -z "${FOLDER_NAME_RETURNED}" ]]; then
  fail "Folder '${FOLDER_NAME}' does not exist — run sftpgo_setup.sh"
else
  pass "Folder '${FOLDER_NAME}' exists"

  MAPPED=$(echo "${FOLDER_JSON}" | jq -r '.mapped_path // empty')
  if [[ "${MAPPED}" == "${FOLDER_LOCAL_PATH}" ]]; then
    pass "Mapped path: ${MAPPED}"
  else
    fail "Mapped path mismatch — got '${MAPPED}', expected '${FOLDER_LOCAL_PATH}'"
  fi
fi

# ---------------------------------------------------------------------------
# 4. User config
# ---------------------------------------------------------------------------
header "User: ${SFTPGO_USER}"

USER_JSON=$(curl -sf --max-time 15 \
  -H "${AUTH}" \
  "${API}/users/${SFTPGO_USER}" 2>/dev/null || echo "{}")

USERNAME=$(echo "${USER_JSON}" | jq -r '.username // empty')
if [[ -z "${USERNAME}" ]]; then
  fail "User '${SFTPGO_USER}' not found"
  # Cannot run further user checks
  FAIL_COUNT=$((FAIL_COUNT + 4))
else
  pass "User '${SFTPGO_USER}' found"

  # Status
  U_STATUS=$(echo "${USER_JSON}" | jq -r '.status // 0')
  if [[ "${U_STATUS}" == "1" ]]; then
    pass "User status: active"
  else
    fail "User status: DISABLED (status=${U_STATUS})"
  fi

  # quota_size
  Q_SIZE=$(echo "${USER_JSON}" | jq -r '.quota_size // 0')
  if [[ "${Q_SIZE}" == "${EXPECTED_QUOTA_SIZE}" ]]; then
    pass "quota_size: ${Q_SIZE}"
  else
    fail "quota_size regression — got ${Q_SIZE}, expected ${EXPECTED_QUOTA_SIZE}"
  fi

  # max_upload_file_size
  MUF=$(echo "${USER_JSON}" | jq -r '.max_upload_file_size // 0')
  if [[ "${MUF}" == "${EXPECTED_MAX_UPLOAD}" ]]; then
    pass "max_upload_file_size: ${MUF}"
  else
    fail "max_upload_file_size regression — got ${MUF}, expected ${EXPECTED_MAX_UPLOAD}"
  fi

  # home_dir
  HOME_DIR=$(echo "${USER_JSON}" | jq -r '.home_dir // empty')
  if [[ "${HOME_DIR}" == "${FOLDER_LOCAL_PATH}" ]]; then
    pass "home_dir: ${HOME_DIR}"
  else
    warn "home_dir is '${HOME_DIR}', expected '${FOLDER_LOCAL_PATH}'"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Virtual folder assignment on user
# ---------------------------------------------------------------------------
header "Virtual Folder Assignment"

VF_MATCH=$(echo "${USER_JSON}" | jq \
  --arg fn "${FOLDER_NAME}" \
  '[.virtual_folders[]? | select(.name == $fn)]')

VF_COUNT=$(echo "${VF_MATCH}" | jq 'length')

if [[ "${VF_COUNT}" -lt 1 ]]; then
  fail "Folder '${FOLDER_NAME}' not assigned to user '${SFTPGO_USER}'"
else
  pass "Folder '${FOLDER_NAME}' assigned to user"

  VF_PATH=$(echo "${VF_MATCH}" | jq -r '.[0].virtual_path // empty')
  if [[ "${VF_PATH}" == "${FOLDER_VIRTUAL_PATH}" ]]; then
    pass "virtual_path: ${VF_PATH}"
  else
    fail "virtual_path mismatch — got '${VF_PATH}', expected '${FOLDER_VIRTUAL_PATH}'"
  fi

  VF_QUOTA=$(echo "${VF_MATCH}" | jq -r '.[0].quota_size // 0')
  if [[ "${VF_QUOTA}" == "${EXPECTED_QUOTA_SIZE}" ]]; then
    pass "virtual_folder quota_size: ${VF_QUOTA}"
  else
    fail "virtual_folder quota_size regression — got ${VF_QUOTA}, expected ${EXPECTED_QUOTA_SIZE}"
  fi
fi

# ---------------------------------------------------------------------------
# 6. User JWT (user-level token endpoint)
# ---------------------------------------------------------------------------
header "User Token Endpoint"

if [[ -n "${SFTPGO_USER_PASS:-}" ]]; then
  USER_AUTH_RAW=$(curl -sf --max-time 15 \
    -u "${SFTPGO_USER}:${SFTPGO_USER_PASS}" \
    "${API}/user/token" 2>/dev/null || echo "{}")
  USER_TOKEN=$(echo "${USER_AUTH_RAW}" | jq -r '.access_token // empty')
  if [[ -n "${USER_TOKEN}" ]]; then
    pass "User JWT acquired for '${SFTPGO_USER}'"
  else
    fail "User '${SFTPGO_USER}' could not obtain JWT (wrong password or account locked)"
  fi
else
  warn "SFTPGO_USER_PASS not set — skipping user-level auth check"
fi

# ---------------------------------------------------------------------------
# 7. Quota scan trigger
# ---------------------------------------------------------------------------
header "Quota Scan"

SCAN_HTTP=$(curl -so /dev/null -w "%{http_code}" --max-time 20 -X POST \
  -H "${AUTH}" \
  "${API}/quotas/users/${SFTPGO_USER}/scan" || echo "000")

case "${SCAN_HTTP}" in
  200|202) pass "Quota scan accepted (HTTP ${SCAN_HTTP})" ;;
  409)     pass "Quota scan already running (HTTP 409) — OK" ;;
  *)       fail "Quota scan returned unexpected HTTP ${SCAN_HTTP}" ;;
esac

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "════════════════════════════════════════════"
echo " Validation complete"
echo " Passed:   ${PASS_COUNT}"
echo " Warnings: ${WARN_COUNT}"
echo " Failed:   ${FAIL_COUNT}"
echo "════════════════════════════════════════════"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo ""
  echo "ACTION REQUIRED: ${FAIL_COUNT} check(s) failed."
  echo "Run sftpgo_setup.sh to restore expected configuration."
  exit 1
fi

exit 0
