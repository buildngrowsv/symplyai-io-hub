#!/usr/bin/env bash
#
# setup-symplyai-io-email-routing-via-cloudflare-api.sh
# =============================================================================
# PURPOSE (product + ops narrative):
# Cloudflare Email Routing is FREE — no Privacy.com card, no Google Workspace bill.
# The operator asked for automation because Wrangler’s OAuth token (see `wrangler whoami`)
# typically only carries Workers/Pages/zone-read scopes, not Email Routing writes, so
# `wrangler` cannot complete this flow alone. A dedicated API Token with Email Routing
# permissions can enable routing, register a destination mailbox, and create forward
# rules for adam@ and media@ in one shot (after the destination is verified).
#
# WHY THIS LIVES IN THE HUB REPO:
# symplyai-io-hub is the public company site that advertises @symplyai.io contacts.
# Keeping the automation next to the site reduces drift between “what we promise” and
# “what DNS/MX actually does.”
#
# DEPENDENCIES: bash, curl, jq. Optional: `timeout` (macOS has it).
#
# SECURITY:
# - Export CLOUDFLARE_API_TOKEN only in your interactive shell or CI secret store;
#   never commit it. Prefer a short-lived token scoped to this account/zone.
# - EMAIL_ROUTING_DESTINATION is the real mailbox that receives forwarded mail; it is
#   read only by this script locally — do not log it to public CI logs.
#
set -euo pipefail

API_BASE="https://api.cloudflare.com/client/v4"

# ---------------------------------------------------------------------------
# Defaults match ops logs / wrangler account (override with env when needed).
# Zone id: symplyai.io in Cloudflare (from Github/ops-logs/dns/symplyai-io-cnames.md).
# Account id: from `wrangler whoami` for the logged-in Cloudflare user.
# ---------------------------------------------------------------------------
CF_ZONE_ID="${CF_ZONE_ID:-e7c42edc5a96244534c394dd51779ccb}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-dd5b6e7cbd04f165545572bd23cc015f}"

# Aliases we expose on the public hub (see public/index.html).
CF_CUSTOM_LOCAL_PART_ADAM="${CF_CUSTOM_LOCAL_PART_ADAM:-adam}"
CF_CUSTOM_LOCAL_PART_MEDIA="${CF_CUSTOM_LOCAL_PART_MEDIA:-media}"
DOMAIN="${SYMPLY_DOMAIN:-symplyai.io}"

usage() {
  sed -n '1,120p' "$0" | grep -E '^#' | sed 's/^# \{0,1\}//'
  cat <<EOF

Required environment:
  CLOUDFLARE_API_TOKEN   Bearer token with at least:
                         Account · Email Routing · Edit
                         Zone · Email Routing · Edit
  EMAIL_ROUTING_DESTINATION   Destination mailbox email (must verify via link CF emails you)

Optional:
  CF_ZONE_ID   (default $CF_ZONE_ID)
  CF_ACCOUNT_ID (default $CF_ACCOUNT_ID)
  DRY_RUN=1    Print curl commands only

Create token: Cloudflare Dashboard → My Profile → API Tokens → Create Token
→ use template "Edit zone DNS" as a starting point OR custom with the two Email Routing perms above.

EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "error: CLOUDFLARE_API_TOKEN is not set." >&2
  usage >&2
  exit 2
fi

if [[ -z "${EMAIL_ROUTING_DESTINATION:-}" ]]; then
  echo "error: EMAIL_ROUTING_DESTINATION is not set (the inbox that should receive forwards)." >&2
  usage >&2
  exit 2
fi

cf_curl() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local url="${API_BASE}${path}"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "DRY_RUN: curl -sS -X ${method} ${url} ..." >&2
    return 0
  fi
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required (brew install jq)." >&2
    exit 3
  }
}

require_jq

echo "==> Fetching Email Routing status for zone ${CF_ZONE_ID}..."
STATUS_JSON="$(cf_curl GET "/zones/${CF_ZONE_ID}/email/routing")"
if echo "$STATUS_JSON" | jq -e '.success == true' >/dev/null 2>&1; then
  ENABLED="$(echo "$STATUS_JSON" | jq -r '.result.enabled // false')"
  echo "    enabled=${ENABLED}"
else
  echo "$STATUS_JSON" | jq . >&2 || echo "$STATUS_JSON" >&2
  echo "error: could not read email routing status (check token zone permissions)." >&2
  exit 4
fi

if [[ "${ENABLED}" != "true" ]]; then
  echo "==> Enabling Email Routing (adds/locks MX + SPF for this zone)..."
  EN_JSON="$(cf_curl POST "/zones/${CF_ZONE_ID}/email/routing/enable" '{}')"
  if echo "$EN_JSON" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "    ok"
  else
    echo "$EN_JSON" | jq . >&2 || echo "$EN_JSON" >&2
    echo "error: enable failed." >&2
    exit 5
  fi
else
  echo "==> Email Routing already enabled; skipping enable."
fi

echo "==> Listing destination addresses on account ${CF_ACCOUNT_ID}..."
ADDR_LIST="$(cf_curl GET "/accounts/${CF_ACCOUNT_ID}/email/routing/addresses")"
if ! echo "$ADDR_LIST" | jq -e '.success == true' >/dev/null 2>&1; then
  echo "$ADDR_LIST" | jq . >&2 || echo "$ADDR_LIST" >&2
  echo "error: cannot list destination addresses (need Account Email Routing Edit)." >&2
  exit 6
fi

# ---------------------------------------------------------------------------
# Destination lifecycle: missing → POST create → user clicks verify link in inbox.
# If the row exists but .verified is null, we must NOT create rules yet (API rejects).
# ---------------------------------------------------------------------------
DEST_STATE="$(echo "$ADDR_LIST" | jq -r --arg e "$EMAIL_ROUTING_DESTINATION" '
  ([.result[]? | select(.email == $e)] | first) as $row
  | if $row == null then "missing"
    elif ($row.verified | type) == "null" then "pending"
    else "verified"
    end')"

if [[ "$DEST_STATE" == "missing" ]]; then
  echo "==> Creating destination address (Cloudflare will email a verification link)..."
  CREATE_A="$(cf_curl POST "/accounts/${CF_ACCOUNT_ID}/email/routing/addresses" "$(jq -nc --arg e "$EMAIL_ROUTING_DESTINATION" '{email:$e}')")"
  if echo "$CREATE_A" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "    created; check inbox for Cloudflare verification."
  else
    echo "$CREATE_A" | jq . >&2 || echo "$CREATE_A" >&2
  fi
  echo ""
  echo "NEXT (human): Open the verification email, click the Cloudflare link, then re-run this script."
  exit 0
fi

if [[ "$DEST_STATE" == "pending" ]]; then
  echo "==> Destination is registered but NOT verified yet."
  echo "NEXT (human): Finish verification in the inbox, then re-run this script to create rules."
  exit 0
fi

echo "    destination verified (state=${DEST_STATE})"

echo "==> Ensuring forward rules for ${CF_CUSTOM_LOCAL_PART_ADAM}@${DOMAIN} and ${CF_CUSTOM_LOCAL_PART_MEDIA}@${DOMAIN}..."
RULES_JSON="$(cf_curl GET "/zones/${CF_ZONE_ID}/email/routing/rules")"
if ! echo "$RULES_JSON" | jq -e '.success == true' >/dev/null 2>&1; then
  echo "$RULES_JSON" | jq . >&2
  exit 7
fi

# Cloudflare uses numeric priority; higher = evaluated first in some UIs — we only need stability.
PRI_BASE=100
for pair in "${CF_CUSTOM_LOCAL_PART_ADAM}:adam" "${CF_CUSTOM_LOCAL_PART_MEDIA}:media"; do
  LOCAL="${pair%%:*}"
  LABEL="${pair##*:}"
  TO_ADDR="${LOCAL}@${DOMAIN}"
  EXISTS="$(echo "$RULES_JSON" | jq -r --arg to "$TO_ADDR" '[.result[]? | select(.matchers[]? | select(.field=="to" and .value==$to))] | length')"
  if [[ "$EXISTS" -gt 0 ]]; then
    echo "    rule for ${TO_ADDR} already exists; skip."
    continue
  fi
  BODY="$(jq -nc \
    --arg name "Forward ${TO_ADDR}" \
    --arg to "$TO_ADDR" \
    --arg dest "$EMAIL_ROUTING_DESTINATION" \
    --argjson pri "$PRI_BASE" \
    '{
      name: $name,
      enabled: true,
      priority: $pri,
      matchers: [{type:"literal", field:"to", value:$to}],
      actions: [{type:"forward", value:[$dest]}]
    }')"
  echo "    creating rule: ${TO_ADDR} -> (destination mailbox)"
  RESP="$(cf_curl POST "/zones/${CF_ZONE_ID}/email/routing/rules" "$BODY")"
  if echo "$RESP" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "        ok"
  else
    echo "$RESP" | jq . >&2 || echo "$RESP" >&2
    echo "error: failed to create rule for ${TO_ADDR}" >&2
    exit 8
  fi
  PRI_BASE=$((PRI_BASE + 1))
done

echo ""
echo "Done. Send test mail from an external account to adam@${DOMAIN} and media@${DOMAIN}."
