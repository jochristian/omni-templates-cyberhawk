#!/usr/bin/env bash
set -euo pipefail

# Operator daily SSH cert signing. Run on your workstation.

if [[ -z "${BAO_ADDR:-}" || -z "${BAO_TOKEN:-}" ]]; then
  echo "ERROR: BAO_ADDR and BAO_TOKEN must be set."
  echo ""
  echo "  kubectl port-forward svc/openbao 8200:8200 -n openbao &"
  echo "  export BAO_ADDR=http://127.0.0.1:8200"
  echo "  export BAO_TOKEN=<token from bao login>"
  exit 1
fi

# Detect SSH public key
if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
  KEYNAME="id_ed25519"
elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
  KEYNAME="id_rsa"
else
  echo "ERROR: No SSH public key found at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub"
  echo "Generate one with: ssh-keygen -t ed25519"
  exit 1
fi

PUBKEY="$HOME/.ssh/${KEYNAME}.pub"
CERTPATH="$HOME/.ssh/${KEYNAME}-cert.pub"

# Check existing cert validity
if [[ -f "$CERTPATH" ]]; then
  VALID_LINE=$(ssh-keygen -Lf "$CERTPATH" 2>/dev/null | grep "Valid:" || true)
  if [[ -n "$VALID_LINE" ]]; then
    EXPIRY=$(echo "$VALID_LINE" | grep -oE 'to [^ ]+' | cut -d' ' -f2)
    echo "Existing cert valid until: $EXPIRY"
    read -rp "Re-sign anyway? [y/N]: " RESIGN
    [[ "$RESIGN" =~ ^[Yy]$ ]] || { echo "Keeping existing cert."; exit 0; }
  fi
fi

echo "Signing $PUBKEY against ssh-client-signer/sign/human-access..."
bao write -field=signed_key \
  ssh-client-signer/sign/human-access \
  public_key=@"$PUBKEY" \
  > "$CERTPATH"
chmod 600 "$CERTPATH"

echo ""
ssh-keygen -Lf "$CERTPATH"

echo ""
echo "Ready to use:"
echo "  ssh -i $CERTPATH -i $HOME/.ssh/$KEYNAME ubuntu@<host>"
