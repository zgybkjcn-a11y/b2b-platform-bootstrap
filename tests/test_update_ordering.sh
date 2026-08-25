#!/usr/bin/env bash
#
# Regression test for the Caddy start-ordering defect that made every
# `b2b-platform update` fail between v0.1.7 and v0.1.13.
#
# Background
# ----------
# compose.yml gives `web` a healthcheck and declares
#     caddy: depends_on: { web: { condition: service_healthy } }
# If update.sh starts caddy BEFORE the application images are upgraded,
# that healthcheck is evaluated against the *previous* web image, fails,
# and the update rolls the control files back -- restoring the defective
# update.sh along with them, so the deployment can never self-heal.
#
# The fix is ordering: `up -d caddy` must run only after
# `b2b-platform upgrade` has bumped APP_VERSION.
#
# This test pins that ordering from both sides:
#   case 1  the committed update.sh completes the update
#   case 2  a mutant that starts caddy early is REJECTED
# Case 2 is the important half. Without it case 1 could pass vacuously.

set -Eeuo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
. "$TEST_DIR/lib/sandbox.sh"

OLD=v0.1.7
NEW=v0.1.13
STUB_OLD_VERSION=$OLD

trap sandbox_destroy EXIT

# --------------------------------------------------------------- case 1
# The committed update.sh must drive the update to completion.

sandbox_create "$OLD"

status=0
output=$(sandbox_run "$SANDBOX/update.sh" --version "$NEW") || status=$?

if ((status != 0)); then
  printf '  FAIL - committed update.sh could not complete the update (exit %d)\n' "$status" >&2
  printf '%s\n' "$output" | sed 's/^/           /' >&2
  exit 1
fi
ok "committed update.sh exits 0"

assert_contains "$output" "Updated from $OLD to $NEW" \
  "committed update.sh reports the completed update"

# Prove we actually reached the final step rather than short-circuiting.
grep -q 'up -d caddy' "$SANDBOX/docker.log" \
  || fail "caddy was never started -- the test did not exercise the final step"
ok "caddy is started"

assert_equals "$(sed -n 's/^APP_VERSION=//p' "$SANDBOX/.env" | tail -1)" "$NEW" \
  "APP_VERSION is left at the new version"

sandbox_destroy

# --------------------------------------------------------------- case 2
# Negative control: reconstruct the defect and require the harness to
# catch it.

sandbox_create "$OLD"

mutant=$SANDBOX/update-mutant.sh
awk '
  /^upgrade_log=/ && !inserted {
    print "if ! \"${new_compose[@]}\" up -d caddy; then"
    print "  restore_and_restart_caddy"
    print "  fail \"new control files could not start Caddy; restored control files\""
    print "fi"
    inserted = 1
  }
  { print }
' "$SANDBOX/update.sh" > "$mutant"
chmod 0755 "$mutant"

# Confirm the mutation landed: exactly one extra early `up -d caddy`.
orig_count=$(grep -c 'up -d caddy' "$SANDBOX/update.sh" || true)
mut_count=$(grep -c 'up -d caddy' "$mutant" || true)
assert_equals "$mut_count" "$((orig_count + 1))" \
  "mutation adds one premature caddy start"

status=0
output=$(sandbox_run "$mutant" --version "$NEW") || status=$?

((status != 0)) || fail \
  "negative control PASSED -- this harness cannot detect the ordering defect"
ok "mutant exits non-zero"

assert_contains "$output" "could not start Caddy" \
  "starting caddy before the image upgrade is rejected"

# The defining symptom of the production outage: the version never moves,
# so re-running the update repeats the same failure forever.
assert_equals "$(sed -n 's/^APP_VERSION=//p' "$SANDBOX/.env" | tail -1)" "$OLD" \
  "mutant leaves APP_VERSION unchanged (cannot self-heal)"
