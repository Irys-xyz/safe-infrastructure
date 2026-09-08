# Tests

Regression tests for the operational scripts. Zero dependencies beyond `bash`, `awk`, `sed`,
`python3` and — for three of them — `docker`.

```bash
tests/run.sh                    # everything
tests/run.sh restore digest     # only tests whose name matches one of these substrings
tests/run.sh --prove            # also run against BASE_REF (default HEAD) and check the
                                # regression tests actually fail there
```

Tests needing something the machine lacks report `SKIP` rather than passing, because a suite
that silently skips has the same failure mode as a check that silently passes.

## What is tested, and why only this

Not coverage — the scripts are mostly orchestration, and a test that asserts `docker compose up`
was called tells you nothing you did not already know. What is here is the behaviour that is
**surprising**: places where the obvious reading of the code is wrong, so a future edit is
likely to reintroduce the bug. Each test's header says what that surprise is.

| Test | The non-obvious thing |
|---|---|
| `db_restore_reports_failure` | `psql` runs past every SQL error and still exits 0 unless `ON_ERROR_STOP=1`. The restore is the branch's only rollback path, and it printed `ok` for a restore that did not apply. |
| `rehearsal_tree_excludes_secrets` | Gitignoring a file keeps it out of the *repository*, not out of a `tar` of the working tree. The rehearsal ran on the operator's real secrets. |
| `absent_contracts_are_blocking` | A Safe proxy factory present without its matching singleton lets the wallet deploy a bricked Safe. The check recorded that as a warning and exited 0. |
| `diff_fails_on_migration_regression` | Flagging a regression and failing on it are two different things; the counter was initialised after the loop that should have incremented it. |
| `pin_digests_matches_official_images` | Podman reports official images as `docker.io/library/postgres`. Stripping only `docker.io/` matched nothing, so half the digests were never emitted — on the production runtime only. |
| `version_check_accepts_digest_pinned_images` | In `repo:v6.10.1@sha256:…`, `${ref##*:}` is the digest, not the tag. Pinning correctly made the check fail. |
| `image_tag_ignores_digest` | Edge cases of the same rule: registry ports, digest-only references. |
| `unhealthy_counts_missing_services` | `compose ps` has no row for a service it failed to create, so a stack that never came up was "all services healthy". |
| `compose_requires_credentials` | Unset credentials fell back to the published upstream defaults. Also that podman-compose's parser resolves the YAML anchors the credentials now live in. |
| `ui_build_failure_stops_the_deploy` | A failed wallet build fell through, so the deploy reported success while serving the previous signing bundle. |
| `test_dir_guard_refuses_a_live_stack` | `TEST_DIR` is settable and its `./data` is deleted recursively; pointed at a real stack it destroyed four production databases. |
| `configure_irys_fails_when_stack_is_down` | `exit` inside `$(…)` leaves only the subshell. |
| `currency_logo_rejects_non_png` | One path validated the PNG magic bytes and its sibling did not, so a mistyped argument became the native currency's icon. |
| `anvil_fork_resolves_a_concrete_block` | Without `--block-time` anvil's head freezes the moment a transaction is included, and anything awaiting confirmations hangs forever. |
| `usage_text_is_complete` | Usage text printed by a hand-maintained line range drifts, and nobody reads usage text until they are stuck. |

## `--prove`

A regression test written after its fix passes on the first run, which proves nothing: it may be
asserting the wrong thing, or nothing at all. `--prove` extracts `BASE_REF` (default `HEAD`) to a
temporary tree, runs the suite against it, and requires that every test declaring

```
# expect-fail-against-base: yes
```

**fails there, with a real assertion failure** — a test that errors before it asserts anything is
reported as `ERRORED`, not as proof. It prints which assertions failed, so "it failed" can be
checked against "it failed for the right reason".

So the workflow for a new fix is: write the test, run `tests/run.sh --prove` **before**
committing (the working tree has the fix, `HEAD` does not), and read the failure it reports
against `HEAD`. After committing, pass the pre-fix revision explicitly:
`BASE_REF=<sha> tests/run.sh --prove`.

`expect-fail-against-base: no` means the behaviour was already correct and the test guards it.
`unprovable` requires an `unprovable-because:` line and is reported separately — such a test
rests on review rather than demonstration, and saying so is better than implying otherwise.
