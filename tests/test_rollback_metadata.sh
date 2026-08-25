#!/usr/bin/env bash
#
# Regression test for how `b2b-platform upgrade` handles the release
# metadata that declares rollback compatibility.
#
# The check used to be a single pipeline:
#
#     if curl -fsSL "$BOOTSTRAP_BASE/versions/$next.json" | grep -Fq "\"$previous\""
#
# which collapsed two different facts into one branch: "the release
# declares no compatible predecessor" and "we could not find out". Because
# `set -e` does not apply to an `if` condition, a transient fetch failure
# landed in the else branch, deleted rollback-version, printed a claim
# about content that was never read, and continued into `run --rm migrate`
# -- a migration that is never downgraded.
#
# Three outcomes must stay distinguishable, so all three are pinned here.

set -Eeuo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
. "$TEST_DIR/lib/sandbox.sh"

OLD=v0.1.7
STUB_OLD_VERSION=$OLD

trap sandbox_destroy EXIT

# Build a fixture BOOTSTRAP_BASE rather than leaning on the repository's
# real versions/*.json, whose contents change with every release.
#
#   v0.2.0  declares OLD compatible
#   v0.3.0  declares nothing compatible
#   v9.9.9  deliberately absent -- the stub curl fails for a missing file,
#           which is how both an unreachable and an unpublished manifest
#           present themselves to the caller
make_fixture() {
  local dir=$SANDBOX/bootstrap/versions
  mkdir -p "$dir"
  printf '{"version":"v0.2.0","rollbackCompatibleFrom":["%s"]}\n' "$OLD" > "$dir/v0.2.0.json"
  printf '{"version":"v0.3.0","rollbackCompatibleFrom":[]}\n' > "$dir/v0.3.0.json"
  SANDBOX_BOOTSTRAP_BASE=$SANDBOX/bootstrap
}

marker() {
  if [[ -f $SANDBOX/rollback-version ]]; then
    tr -d '\n' < "$SANDBOX/rollback-version"
  else
    printf '(absent)'
  fi
}

app_version() { sed -n 's/^APP_VERSION=//p' "$SANDBOX/.env" | tail -1; }

# ------------------------------------------------- unreadable, no override
sandbox_create "$OLD"; make_fixture

status=0
out=$(sandbox_run "$SANDBOX/b2b-platform" upgrade v9.9.9) || status=$?

((status != 0)) || fail "an unreadable manifest did not stop the upgrade"
ok "an unreadable manifest stops the upgrade"

assert_contains "$out" "rollback compatibility is UNKNOWN" \
  "the message reports unknown compatibility, not a release decision"

# The defining property: nothing was changed, so a retry is safe.
assert_equals "$(app_version)" "$OLD" "APP_VERSION is untouched when refused"
assert_equals "$(marker)" "(absent)" "no rollback marker is written when refused"

sandbox_destroy

# ----------------------------------------------------- unreadable, override
sandbox_create "$OLD"; make_fixture

status=0
out=$(sandbox_run "$SANDBOX/b2b-platform" upgrade v9.9.9 --allow-unknown-rollback) || status=$?

((status == 0)) || fail "--allow-unknown-rollback did not permit the upgrade: $out"
ok "--allow-unknown-rollback permits the upgrade"

assert_contains "$out" "continuing without a rollback path" \
  "the override says plainly that there is no rollback path"
assert_equals "$(marker)" "(absent)" "the override leaves no rollback marker"

sandbox_destroy

# -------------------------------------------------- readable and compatible
sandbox_create "$OLD"; make_fixture

status=0
out=$(sandbox_run "$SANDBOX/b2b-platform" upgrade v0.2.0) || status=$?

((status == 0)) || fail "a compatible release failed to upgrade: $out"
assert_contains "$out" "Upgraded to v0.2.0" "a compatible release upgrades"
assert_equals "$(marker)" "$OLD" "the previous version is recorded for rollback"

sandbox_destroy

# ------------------------------------------------ readable but incompatible
sandbox_create "$OLD"; make_fixture

status=0
out=$(sandbox_run "$SANDBOX/b2b-platform" upgrade v0.3.0) || status=$?

((status == 0)) || fail "an incompatible release should still upgrade: $out"
assert_contains "$out" "does not declare $OLD schema-compatible" \
  "an incompatible release keeps the original wording"
assert_equals "$(marker)" "(absent)" "an incompatible release records no marker"

sandbox_destroy

# ------------------------------------------------------------ option parsing
sandbox_create "$OLD"; make_fixture

status=0
out=$(sandbox_run "$SANDBOX/b2b-platform" upgrade --bogus-option) || status=$?
((status != 0)) || fail "an unknown option was accepted"
assert_contains "$out" "unknown option for upgrade" "unknown options are rejected"

status=0
out=$(sandbox_run "$SANDBOX/b2b-platform" upgrade --allow-unknown-rollback) || status=$?
((status != 0)) || fail "the flag alone, with no version, was accepted"
assert_contains "$out" "usage: b2b-platform upgrade" \
  "the flag alone, with no version, prints usage"
