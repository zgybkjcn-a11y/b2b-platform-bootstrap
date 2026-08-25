# Tests

```bash
bash tests/run-tests.sh
```

No network, no GHCR credentials, no real containers required. Tests that do
need docker (`test_caddyfiles.sh`, `test_compose_config.sh`) report SKIP
rather than FAIL when it is unavailable.

Set `REQUIRE_DOCKER=1` to turn that skip into a failure. CI does this,
because the runner always has docker and a skip there would report green
while checking nothing:

```bash
REQUIRE_DOCKER=1 bash tests/run-tests.sh
```

## How the hermetic tests work

`update.sh` and `b2b-platform` are driven against a `mktemp -d` sandbox
instead of `/opt/b2b-platform`, with stub `docker`, `curl` and `id` in front
of `PATH`:

| stub | behaviour |
| --- | --- |
| `docker` | Succeeds for everything except `up` including `caddy` while `.env` still holds the pre-upgrade `APP_VERSION` — that fails, mirroring the real healthcheck rejection. Logs every call to `$STUB_DOCKER_LOG`. |
| `curl` | Serves `$BOOTSTRAP_BASE/*` from the working tree; succeeds for `$PUBLIC_ORIGIN/health`. **Any other URL fails**, which proves the control scripts make no unexpected network calls. |
| `id` | Reports uid 0 for `id -u`, since both scripts refuse to run unprivileged. |

The sandbox is built by `tests/lib/sandbox.sh` and its `.env` is tuned to
satisfy every check in `b2b-platform doctor` — including
`tenant_encryption_check`, which requires the active key to base64-decode to
exactly 32 bytes. All credential-shaped values there are placeholders.

Testing this way requires `INSTALL_DIR` to be overridable, which is why the
three control scripts declare it as `${INSTALL_DIR:-/opt/b2b-platform}`.
Default behaviour is unchanged.

## test_update_ordering.sh

The regression this suite exists for. `compose.yml` gives `web` a
healthcheck and declares:

```yaml
caddy:
  depends_on: { web: { condition: service_healthy } }
```

If `update.sh` starts caddy *before* upgrading the application images, that
healthcheck is evaluated against the **previous** web image, fails, and the
update rolls the control files back — restoring the defective `update.sh`
too, so the deployment can never self-heal. This is what broke every
v0.1.7 → v0.1.13 update.

The test pins the ordering from both sides:

1. the committed `update.sh` completes the update, and
2. a **mutant** with an extra premature `up -d caddy` is rejected.

Case 2 is the load-bearing half. Without it case 1 could pass vacuously —
a harness that cannot fail proves nothing. It mutates by *inserting* an
early caddy start rather than relocating code, so it stays robust across
refactors of `update.sh`.

## Adding a test

Drop a `test_*.sh` into `tests/`, source `lib/assert.sh`, and exit 0 / 77 /
non-zero. `run-tests.sh` picks it up automatically.
