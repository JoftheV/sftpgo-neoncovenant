#!/usr/bin/env bash
# =============================================================================
# SFTPGo Virtual Folder Automation Script
# Host:    home.neoncovenant.appboxes.co:27580 (WebDAV/API/Admin)
# User:    jofthev  (maps to /home/appbox/data/jofthev)
# Purpose: Create virtual folder, assign to user with 1 GB upload quota,
#          and configure Cloudflare mTLS client-cert access from MacBook Pro
# Requires: curl, jq
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. CONFIGURATION — edit these before running
# ---------------------------------------------------------------------------
SFTPGO_ADMIN_URL="https://home.neoncovenant.appboxes.co:27580"   # SFTPGo web UI base URL
ADMIN_USER="admin"                                      # SFTPGo admin username
ADMIN_PASS="YOUR_ADMIN_PASSWORD"                        # SFTPGo admin password

SFTPGO_USER="jofthev"                                  # SFTPGo user account name
SFTPGO_USER_PASS="YOUR_USER_PASSWORD"                  # SFTPGo user account password
SFTPGO_USER_EMAIL="jofthev@neoncovenant.com"           # User email (optional)

FOLDER_NAME="jofthev_data"                             # Unique folder identifier in SFTPGo
FOLDER_LOCAL_PATH="/home/appbox/data/jofthev"          # Absolute path on appbox disk
FOLDER_VIRTUAL_PATH="/data"                            # Virtual path seen by the SFTP user

QUOTA_SIZE_BYTES=$((1 * 1024 * 1024 * 1024))          # 1 GB = 1073741824 bytes
QUOTA_FILES=0                                          # 0 = unlimited file count
MAX_UPLOAD_FILE_SIZE=$((1 * 1024 * 1024 * 1024))      # 1 GB per-file upload limit

# Cloudflare mTLS — your MacBook Pro client cert fingerprint (SHA-256 hex, no colons)
# Obtain with: openssl x509 -in client.pem -fingerprint -sha256 -noout | sed 's/://g' | cut -d= -f2
CF_CLIENT_CERT_FINGERPRINT=""   # Leave empty to skip TLS cert pinning on SFTPGo side

API="${SFTPGO_ADMIN_URL}/api/v2"

# ---------------------------------------------------------------------------
# 1. Authenticate — get admin JWT token
# ---------------------------------------------------------------------------
echo "[1/6] Authenticating as admin..."
ADMIN_TOKEN=$(curl -sf \
  -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "${API}/token" \
  | jq -r '.access_token')

if [[ -z "${ADMIN_TOKEN}" || "${ADMIN_TOKEN}" == "null" ]]; then
  echo "ERROR: Failed to obtain admin token. Check ADMIN_USER / ADMIN_PASS and SFTPGO_ADMIN_URL."
  exit 1
fi
echo "    Token acquired."

AUTH_HEADER="Authorization: Bearer ${ADMIN_TOKEN}"

# ---------------------------------------------------------------------------
# 2. Create the virtual folder (base folder object in SFTPGo)
# ---------------------------------------------------------------------------
echo "[2/6] Creating virtual folder '${FOLDER_NAME}' → ${FOLDER_LOCAL_PATH}..."

FOLDER_PAYLOAD=$(jq -n \
  --arg name   "${FOLDER_NAME}" \
  --arg path   "${FOLDER_LOCAL_PATH}" \
  --argjson qs  "${QUOTA_SIZE_BYTES}" \
  --argjson qf  "${QUOTA_FILES}" \
'{
  name:        $name,
  mapped_path: $path,
  description: "jofthev primary data volume — local disk",
  filesystem: {
    provider: 0
  },
  used_quota_size:  0,
  used_quota_files: 0,
  last_quota_update: 0,
  users: []
}')

FOLDER_RESPONSE=$(curl -sf -X POST \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d "${FOLDER_PAYLOAD}" \
  "${API}/folders" || true)

# If folder already exists (409), fetch existing — otherwise check for errors
HTTP_STATUS=$(curl -so /dev/null -w "%{http_code}" -X POST \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d "${FOLDER_PAYLOAD}" \
  "${API}/folders" 2>/dev/null || echo "000")

if [[ "${HTTP_STATUS}" == "201" ]]; then
  echo "    Folder created."
elif [[ "${HTTP_STATUS}" == "409" ]]; then
  echo "    Folder '${FOLDER_NAME}' already exists — continuing."
else
  # Re-attempt with proper error capture
  curl -s -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "${FOLDER_PAYLOAD}" \
    "${API}/folders" | jq .
  echo "WARNING: Unexpected status ${HTTP_STATUS}. Continuing — check output above."
fi

# ---------------------------------------------------------------------------
# 3. Build TLS cert list for SFTPGo user (optional mTLS pinning)
# ---------------------------------------------------------------------------
TLS_CERTS_JSON="[]"
if [[ -n "${CF_CLIENT_CERT_FINGERPRINT}" ]]; then
  TLS_CERTS_JSON=$(jq -n --arg fp "${CF_CLIENT_CERT_FINGERPRINT}" '[$fp]')
  echo "[3/6] Pinning client cert fingerprint: ${CF_CLIENT_CERT_FINGERPRINT}"
else
  echo "[3/6] No TLS cert fingerprint set — skipping SFTPGo-level cert pinning."
fi

# ---------------------------------------------------------------------------
# 4. Create (or update) the SFTPGo user with virtual folder + quota
# ---------------------------------------------------------------------------
echo "[4/6] Provisioning SFTPGo user '${SFTPGO_USER}'..."

USER_PAYLOAD=$(jq -n \
  --arg username   "${SFTPGO_USER}" \
  --arg password   "${SFTPGO_USER_PASS}" \
  --arg email      "${SFTPGO_USER_EMAIL}" \
  --arg homedir    "${FOLDER_LOCAL_PATH}" \
  --arg vpath      "${FOLDER_VIRTUAL_PATH}" \
  --arg fname      "${FOLDER_NAME}" \
  --argjson qs     "${QUOTA_SIZE_BYTES}" \
  --argjson qf     "${QUOTA_FILES}" \
  --argjson muf    "${MAX_UPLOAD_FILE_SIZE}" \
  --argjson tls    "${TLS_CERTS_JSON}" \
'{
  status:   1,
  username: $username,
  password: $password,
  email:    $email,
  home_dir: $homedir,
  uid: 0,
  gid: 0,
  max_sessions:          0,
  quota_size:            $qs,
  quota_files:           $qf,
  max_upload_file_size:  $muf,
  upload_bandwidth:      0,
  download_bandwidth:    0,
  permissions: {
    "/": ["*"]
  },
  filters: {
    tls_certs: $tls,
    tls_username: 0,
    deny_protocols:   [],
    allow_protocols:  ["SSH","HTTP","WebDAV"],
    two_factor_protocols: []
  },
  filesystem: {
    provider: 0
  },
  virtual_folders: [
    {
      name:         $fname,
      virtual_path: $vpath,
      quota_size:   $qs,
      quota_files:  $qf
    }
  ],
  description: "MacBookPro user — jofthev appbox data volume"
}')

# Check if user exists
EXISTING_USER=$(curl -sf \
  -H "${AUTH_HEADER}" \
  "${API}/users/${SFTPGO_USER}" 2>/dev/null || echo "NOT_FOUND")

if echo "${EXISTING_USER}" | jq -e '.username' &>/dev/null; then
  echo "    User '${SFTPGO_USER}' already exists — updating..."
  curl -sf -X PUT \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "${USER_PAYLOAD}" \
    "${API}/users/${SFTPGO_USER}" | jq '{username,status,home_dir,virtual_folders}'
  echo "    User updated."
else
  echo "    Creating new user '${SFTPGO_USER}'..."
  curl -sf -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "${USER_PAYLOAD}" \
    "${API}/users" | jq '{username,status,home_dir,virtual_folders}'
  echo "    User created."
fi

# ---------------------------------------------------------------------------
# 5. Trigger quota scan so SFTPGo indexes existing files immediately
# ---------------------------------------------------------------------------
echo "[5/6] Triggering quota scan for '${SFTPGO_USER}'..."
curl -sf -X POST \
  -H "${AUTH_HEADER}" \
  "${API}/quotas/users/${SFTPGO_USER}/scan" | jq .
echo "    Quota scan initiated."

# ---------------------------------------------------------------------------
# 6. Verify — dump user config summary
# ---------------------------------------------------------------------------
echo "[6/6] Verification — current user config:"
curl -sf \
  -H "${AUTH_HEADER}" \
  "${API}/users/${SFTPGO_USER}" \
  | jq '{
      username,
      status,
      home_dir,
      quota_size,
      quota_files,
      max_upload_file_size,
      virtual_folders: [.virtual_folders[]? | {name,virtual_path,quota_size,quota_files}],
      tls_certs: .filters.tls_certs
    }'

echo ""
echo "=========================================="
echo " SFTPGo virtual folder setup complete."
echo " User:          ${SFTPGO_USER}"
echo " Local path:    ${FOLDER_LOCAL_PATH}"
echo " Virtual path:  ${FOLDER_VIRTUAL_PATH}"
echo " Upload quota:  1 GB (per-file + total)"
echo "=========================================="
