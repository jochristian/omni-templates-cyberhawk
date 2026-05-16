#!/usr/bin/env bash
set -euo pipefail

# Runs ON the target host (not via kubectl). Requires root.
# Usage:
#   sudo bash setup-target-host.sh \
#     --client-ca-key "ssh-rsa AAAA..." \
#     [--host-ca-key "ssh-rsa AAAA..."] \
#     [--sign-host-key]

CLIENT_CA_KEY=""
HOST_CA_KEY=""
SIGN_HOST_KEY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-ca-key) CLIENT_CA_KEY="$2"; shift 2 ;;
    --host-ca-key)   HOST_CA_KEY="$2";   shift 2 ;;
    --sign-host-key) SIGN_HOST_KEY=true;  shift   ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: must run as root"; exit 1; }
[[ -n "$CLIENT_CA_KEY" ]] || { echo "ERROR: --client-ca-key is required"; exit 1; }

# Write client CA key
printf '%s\n' "$CLIENT_CA_KEY" > /etc/ssh/trusted-user-ca-keys.pem
chmod 644 /etc/ssh/trusted-user-ca-keys.pem
chown root:root /etc/ssh/trusted-user-ca-keys.pem

# Add TrustedUserCAKeys to sshd_config (idempotent)
if ! grep -qF "TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem" /etc/ssh/sshd_config; then
  echo "TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem" >> /etc/ssh/sshd_config
fi

# Optionally write host CA key
if [[ -n "$HOST_CA_KEY" ]]; then
  printf '%s\n' "$HOST_CA_KEY" > /etc/ssh/ssh_host_ca.pem
  chmod 644 /etc/ssh/ssh_host_ca.pem
  if ! grep -qF "HostKey /etc/ssh/ssh_host_ed25519_key" /etc/ssh/sshd_config; then
    echo "HostKey /etc/ssh/ssh_host_ed25519_key" >> /etc/ssh/sshd_config
  fi
fi

# Test sshd config before reloading
if ! sshd -t; then
  echo "ERROR: sshd config test failed. No changes applied."
  exit 1
fi

# Reload (not restart — avoids dropping active sessions)
systemctl reload ssh 2>/dev/null || systemctl reload sshd
echo "✅ CA trust configured, sshd reloaded"

if [[ "$SIGN_HOST_KEY" == "true" ]]; then
  [[ -n "${BAO_ADDR:-}" ]] || { echo "ERROR: BAO_ADDR not set"; exit 1; }
  [[ -n "${BAO_TOKEN:-}" ]] || { echo "ERROR: BAO_TOKEN not set"; exit 1; }

  [[ -f /etc/ssh/ssh_host_ed25519_key.pub ]] \
    || { echo "ERROR: /etc/ssh/ssh_host_ed25519_key.pub not found"; exit 1; }

  bao write -field=signed_key ssh-host-signer/sign/linux-hosts \
    cert_type=host \
    public_key=@/etc/ssh/ssh_host_ed25519_key.pub \
    > /etc/ssh/ssh_host_ed25519_key-cert.pub
  chmod 640 /etc/ssh/ssh_host_ed25519_key-cert.pub

  if ! grep -qF "HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub" /etc/ssh/sshd_config; then
    echo "HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub" >> /etc/ssh/sshd_config
  fi

  sshd -t || { echo "ERROR: sshd config test failed after host cert config"; exit 1; }
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  echo "✅ Host key signed and HostCertificate configured"
fi
