#!/usr/bin/env bash
# setup-google-auth.sh — one-time developer setup for KEYLESS GCP scopes in the dev kit.
#
# The studio container mints GCP scope tokens from Application Default Credentials (ADC) that
# docker-compose.override.yml mounts from your ~/.config/gcloud. The gotcha this script exists for:
# plain `gcloud auth login` does NOT create ADC — only `gcloud auth application-default login`
# writes the application_default_credentials.json the studio's Google SDK reads. This script makes
# sure the right login ran, and can verify your impersonation rights on the provisioning SA.
#
# Usage:
#   ./scripts/setup-google-auth.sh                    ensure gcloud + ADC (runs the ADC login if missing)
#   ./scripts/setup-google-auth.sh --sa <sa-email>    also verify you can impersonate that service account
#   ./scripts/setup-google-auth.sh --sa <sa-email> --grant
#                                                     if the impersonation check fails, grant yourself
#                                                     roles/iam.serviceAccountTokenCreator ON that SA and
#                                                     enable iamcredentials.googleapis.com, then re-verify.
#                                                     Needs IAM-admin rights (e.g. project Owner) — note
#                                                     Owner alone can GRANT impersonation but not USE it,
#                                                     which is exactly why this flag exists.
#   ./scripts/setup-google-auth.sh --force            re-run the ADC login even if ADC already exists
#
# NOTE: like docker-compose.override.yml, this file is not part of the upstream dev kit, so
# ./scripts/upgrade_dev_kit.sh removes it. It is committed to git — restore with:
#   git checkout -- scripts/setup-google-auth.sh
set -euo pipefail

SA=""; FORCE=0; GRANT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sa) SA="${2:?--sa needs a service account email}"; shift ;;
    --grant) GRANT=1 ;;
    --force) FORCE=1 ;;
    -h|--help) grep -E '^#( |!)' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown flag: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done
[ "$GRANT" = 1 ] && [ -z "$SA" ] && { echo "--grant requires --sa <sa-email>" >&2; exit 1; }

command -v gcloud >/dev/null 2>&1 || {
  echo "ERROR: gcloud CLI not found. Install it first: https://cloud.google.com/sdk/docs/install" >&2
  exit 1
}

ADC="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"

if [ "$FORCE" = 1 ] || [ ! -f "$ADC" ]; then
  [ -f "$ADC" ] || echo "==> No ADC found at $ADC"
  echo "==> Running: gcloud auth application-default login"
  echo "    (this is the login the studio container uses — plain 'gcloud auth login' is not enough)"
  gcloud auth application-default login
else
  echo "==> ADC already present: $ADC"
fi

[ -f "$ADC" ] || { echo "ERROR: ADC login did not produce $ADC" >&2; exit 1; }

# Sanity: the ADC actually yields a token (catches revoked/expired logins without printing the token).
if ! TOKEN_ERR=$(gcloud auth application-default print-access-token 2>&1 >/dev/null); then
  echo "ERROR: ADC exists but cannot mint a token:" >&2
  echo "$TOKEN_ERR" | sed 's/^/    /' >&2
  echo "    Re-run with --force to log in again (or complete any org reauth it asks for)." >&2
  exit 1
fi
echo "    ADC OK — token minting works."

# Optional: prove the tokenCreator grant on the provisioning SA, the exact call the studio's
# GcpStsHelper makes (IAM Credentials generateAccessToken via impersonation).
impersonation_ok() { gcloud auth application-default print-access-token --impersonate-service-account="$SA" >/dev/null 2>&1; }

if [ -n "$SA" ]; then
  echo "==> Verifying impersonation of $SA …"
  if impersonation_ok; then
    echo "    OK — your user can impersonate $SA."
  elif [ "$GRANT" = 1 ]; then
    # SA emails are <name>@<project>.iam.gserviceaccount.com — the project is derivable.
    SA_PROJECT="${SA#*@}"; SA_PROJECT="${SA_PROJECT%%.*}"
    MEMBER="$(gcloud config get-value account 2>/dev/null)"
    [ -n "$MEMBER" ] || { echo "ERROR: no active gcloud account (gcloud auth login first)." >&2; exit 1; }
    echo "==> Impersonation denied — granting roles/iam.serviceAccountTokenCreator to $MEMBER on $SA"
    echo "    (project Owner can GRANT impersonation but does not itself carry it — this is the fix)"
    gcloud services enable iamcredentials.googleapis.com --project="$SA_PROJECT" \
      || echo "    WARNING: could not enable iamcredentials.googleapis.com — continuing (it may already be on)" >&2
    gcloud iam service-accounts add-iam-policy-binding "$SA" \
      --member="user:$MEMBER" --role="roles/iam.serviceAccountTokenCreator" \
      --project="$SA_PROJECT" >/dev/null \
      || { echo "ERROR: grant failed — your account lacks IAM-admin rights on $SA_PROJECT; ask an admin." >&2; exit 1; }
    echo "==> Grant applied — waiting for IAM propagation (can take a minute or two) …"
    ok=0
    for _ in $(seq 1 18); do
      if impersonation_ok; then ok=1; break; fi
      sleep 10; printf '.'
    done
    echo
    if [ "$ok" = 1 ]; then
      echo "    OK — your user can now impersonate $SA."
    else
      echo "ERROR: grant applied but impersonation still denied after ~3 min. IAM propagation can" >&2
      echo "       occasionally take longer — re-run: $0 --sa $SA" >&2
      exit 1
    fi
  else
    echo "ERROR: impersonation failed. Re-run with --grant to fix it yourself (needs IAM-admin/Owner)," >&2
    echo "       or ask an admin to grant your user roles/iam.serviceAccountTokenCreator ON the" >&2
    echo "       service account $SA and enable iamcredentials.googleapis.com in its project." >&2
    exit 1
  fi
fi

cat <<'EOF'

✔ Google auth ready for the dev kit.

Next steps:
  1. ./run.sh                    (creates the cloud credential store the studio reads)
  2. ./scripts/connect-cloud.sh gcp --name <name> --project <project-id> --service-account <sa-email>
     It copies this ADC into the store under <name>, proves the impersonation, and creates the
     Provider (type gcp) → Credential (cloudRoleToAssume + adcRef, no keys) → Scope, attached to the
     extension-dev workspace. Re-run the same command after a new ADC login.
EOF
