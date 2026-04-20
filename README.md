# sftpgo-neoncovenant

Automation script for configuring SFTPGo virtual folders on `neoncovenant.appboxes.co` with Cloudflare mTLS client certificate enforcement and 1 GB upload quota.

---

## Overview

| Item | Value |
|---|---|
| SFTPGo host | `https://neoncovenant.appboxes.co` |
| SFTPGo user | `jofthev` |
| Local disk path | `/home/appbox/data/jofthev` |
| Virtual path (SFTP) | `/data` |
| Upload quota (total) | 1 GiB (1,073,741,824 bytes) |
| Max file size | 1 GiB per file |
| Access control | Cloudflare mTLS — MacBook Pro client certificate |

---

## Files

```
sftpgo_setup.sh   — Full API automation script (create folder, user, quota, verify)
README.md         — This file
```

---

## Prerequisites

```bash
brew install curl jq openssl
```

Ensure `/home/appbox/data/jofthev` exists on the appbox before running:

```bash
ssh appbox@neoncovenant.appboxes.co "mkdir -p /home/appbox/data/jofthev && chmod 750 /home/appbox/data/jofthev"
```

---

## Configuration

Edit the config block at the top of `sftpgo_setup.sh` before running:

```bash
SFTPGO_ADMIN_URL="https://neoncovenant.appboxes.co"
ADMIN_USER="admin"
ADMIN_PASS="YOUR_ADMIN_PASSWORD"

SFTPGO_USER="jofthev"
SFTPGO_USER_PASS="YOUR_USER_PASSWORD"

FOLDER_NAME="jofthev_data"
FOLDER_LOCAL_PATH="/home/appbox/data/jofthev"
FOLDER_VIRTUAL_PATH="/data"

CF_CLIENT_CERT_FINGERPRINT=""   # see below
```

---

## Cloudflare mTLS Client Certificate Fingerprint

The script accepts an optional SHA-256 fingerprint of your MacBook Pro Cloudflare
client certificate. When set, SFTPGo pins the cert at the user level via
`filters.tls_certs` — providing a second layer of enforcement beyond what
Cloudflare Access already enforces at the edge.

### Step 1 — Locate your client certificate PEM

If you generated the cert in a prior session and imported it to Keychain,
export it back to PEM for fingerprinting:

```bash
# If you still have client.pem on disk:
ls ~/certs/cloudflare/client.pem

# If it's only in Keychain, export via Keychain Access:
# Keychain Access → find cert → File → Export Items → Save as .p12
# Then convert back to PEM:
openssl pkcs12 -in ~/Downloads/client.p12 \
  -clcerts -nokeys -out ~/certs/cloudflare/client.pem \
  -legacy
```

### Step 2 — Extract the SHA-256 fingerprint

```bash
openssl x509 \
  -in ~/certs/cloudflare/client.pem \
  -fingerprint -sha256 -noout \
  | sed 's/SHA256 Fingerprint=//' \
  | tr -d ':'
```

Example output:
```
A3F2C1B09E4D7F83AA12CC56890BDEF1234567890ABCDEF1234567890ABCDEF12
```

### Step 3 — Paste into the script config

```bash
CF_CLIENT_CERT_FINGERPRINT="A3F2C1B09E4D7F83AA12CC56890BDEF1234567890ABCDEF1234567890ABCDEF12"
```

### Step 4 — Verify mTLS is working at the Cloudflare edge

```bash
# Without cert — should return 403 Forbidden
curl -I https://neoncovenant.appboxes.co/web/admin/login

# With cert — should return 200
curl -I \
  --cert ~/certs/cloudflare/client.pem \
  --key  ~/certs/cloudflare/client-key.pem \
  https://neoncovenant.appboxes.co/web/admin/login
```

---

## Running the Script

```bash
chmod +x sftpgo_setup.sh
bash sftpgo_setup.sh
```

The script runs 6 steps and prints status after each:

| Step | Action |
|---|---|
| 1 | Authenticate as admin → get JWT token |
| 2 | Create virtual folder object (`jofthev_data` → `/home/appbox/data/jofthev`) |
| 3 | Prepare TLS cert pin list (if fingerprint is set) |
| 4 | Create or update `jofthev` user with virtual folder + quota |
| 5 | Trigger quota scan (see below) |
| 6 | Verify and print final user config summary |

The script is **idempotent** — safe to re-run after config changes. It detects
whether the user and folder already exist and performs PUT (update) instead of POST.

---

## Quota Scan

The quota scan (Step 5) tells SFTPGo to walk the filesystem and index all existing
files under the user's home directory and virtual folders. This is required when:

- Files were placed in `/home/appbox/data/jofthev` before the user was created
- Quota counters are showing 0 despite files being present
- You manually moved or added files outside of SFTPGo

The script triggers it automatically via:

```bash
POST /api/v2/quotas/users/jofthev/scan
```

### Manual quota scan (run anytime)

```bash
ADMIN_TOKEN=$(curl -sf \
  -u "admin:YOUR_ADMIN_PASSWORD" \
  "https://neoncovenant.appboxes.co/api/v2/token" \
  | jq -r '.access_token')

# Scan user quota
curl -sf -X POST \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "https://neoncovenant.appboxes.co/api/v2/quotas/users/jofthev/scan" | jq .

# Scan virtual folder quota separately
curl -sf -X POST \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "https://neoncovenant.appboxes.co/api/v2/quotas/folders/jofthev_data/scan" | jq .
```

### Check current quota usage

```bash
curl -sf \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "https://neoncovenant.appboxes.co/api/v2/users/jofthev" \
  | jq '{
      quota_size,
      used_quota_size,
      quota_files,
      used_quota_files,
      virtual_folders: [.virtual_folders[]? | {
        name, virtual_path, quota_size, used_quota_size
      }]
    }'
```

---

## SSH / SFTP Access (MacBook Pro)

SFTP uses SSH key auth independently of Cloudflare mTLS (which protects WebDAV/HTTPS).

### Add SSH public key to SFTPGo user

```bash
PUBKEY=$(cat ~/.ssh/id_ed25519_sftpgo.pub)

curl -sf -X PUT \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://neoncovenant.appboxes.co/api/v2/users/jofthev" \
  -d "$(curl -sf -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "https://neoncovenant.appboxes.co/api/v2/users/jofthev" \
    | jq --arg pk "${PUBKEY}" '.public_keys = [$pk]')"
```

### `~/.ssh/config` entry

```sshconfig
Host appbox-sftpgo
    HostName        neoncovenant.appboxes.co
    Port            2022
    User            jofthev
    IdentityFile    ~/.ssh/id_ed25519_sftpgo
    StrictHostKeyChecking yes
    ServerAliveInterval 60
```

```bash
sftp appbox-sftpgo
sftp appbox-sftpgo:/data
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `403` on all HTTPS requests | Client cert not presented — check Keychain trust or use `--cert`/`--key` flags |
| `401` on API calls | Admin JWT expired — re-run auth step to get fresh token |
| Quota shows 0 despite files | Run manual quota scan for user + folder |
| Virtual folder path missing at login | SFTPGo auto-creates on first login, or run `mkdir -p /home/appbox/data/jofthev` on appbox |
| SFTP connection refused | Confirm port 2022 is open; Cloudflare Tunnel does not proxy raw TCP |
| `409` on folder creation | Folder already exists — script handles this gracefully and continues |
