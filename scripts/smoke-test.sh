#!/usr/bin/env bash
# Post-deployment smoke tests.
# Called by CI after terraform apply + rollout.
# Exit code 1 = deployment fails.

set -euo pipefail

BASE_URL="${API_BASE_URL:-http://localhost:8000}"
PASS=0
FAIL=0

green() { echo -e "\033[0;32m✓ $*\033[0m"; }
red()   { echo -e "\033[0;31m✗ $*\033[0m"; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    green "$label"
    ((PASS++))
  else
    red "$label  (expected='$expected' got='$actual')"
    ((FAIL++))
  fi
}

echo "=== Smoke Tests: $BASE_URL ==="

# ── Health check ──────────────────────────────────────────────────────────────
STATUS=$(curl -sf "$BASE_URL/health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")
assert_eq "GET /health returns ok" "ok" "$STATUS"

# ── Test 1: Valid txhash + vendorA → success ──────────────────────────────────
RESP=$(curl -sf -X POST "$BASE_URL/transfer" \
  -H "Content-Type: application/json" \
  -d '{"amount": 100, "vendor": "vendorA", "txhash": "0x123abc"}')

STATUS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
VENDOR_STATUS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['vendor_response']['status'])")
assert_eq "vendorA + valid txhash → status=success" "success" "$STATUS"
assert_eq "vendorA + valid txhash → vendor_response.status=success" "success" "$VENDOR_STATUS"

# ── Test 2: Valid txhash + vendorB → pending ──────────────────────────────────
RESP=$(curl -sf -X POST "$BASE_URL/transfer" \
  -H "Content-Type: application/json" \
  -d '{"amount": 50, "vendor": "vendorB", "txhash": "0xdeadbeef"}')

VENDOR_STATUS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['vendor_response']['status'])")
assert_eq "vendorB + valid txhash → vendor_response.status=pending" "pending" "$VENDOR_STATUS"

# ── Test 3: Invalid txhash format → 422 ──────────────────────────────────────
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/transfer" \
  -H "Content-Type: application/json" \
  -d '{"amount": 100, "vendor": "vendorA", "txhash": "not-a-hash"}')
assert_eq "Invalid txhash format → 422" "422" "$HTTP_CODE"

# ── Test 4: Unknown vendor → 400 ─────────────────────────────────────────────
RESP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/transfer" \
  -H "Content-Type: application/json" \
  -d '{"amount": 100, "vendor": "vendorZ", "txhash": "0x123abc"}')
assert_eq "Unknown vendor → 400" "400" "$RESP_CODE"

# ── Test 5: Negative amount → 422 ────────────────────────────────────────────
RESP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/transfer" \
  -H "Content-Type: application/json" \
  -d '{"amount": -1, "vendor": "vendorA", "txhash": "0x123abc"}')
assert_eq "Negative amount → 422" "422" "$RESP_CODE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  red "SMOKE TESTS FAILED — blocking deployment"
  exit 1
else
  green "All smoke tests passed"
  exit 0
fi
