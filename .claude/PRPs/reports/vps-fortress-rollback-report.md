# Implementation Report: `--rollback` Recovery Flag

## Summary
Added `setup.sh --rollback` (with `--yes`/`-y` to skip the confirmation prompt) so a user with console/serial access can undo the SSH-locking changes from a botched run in one shot. Restores `sshd_config.bak`, reopens port 22 and removes the recorded custom port from UFW/firewalld, stops Fail2Ban (after `unban --all`), and restarts sshd. Leaves the new user, installed packages, and Step 7 auto-updates intact — those aren't the bricking risk. If `sshd_config.bak` is missing, the script dies with copy-pastable manual recovery instructions instead of half-restoring.

## Assessment vs Reality

| Metric | Predicted (Plan) | Actual |
|---|---|---|
| Complexity | Small | Small |
| Files Changed | 3 | 3 |
| `setup.sh` delta | ~20 lines (PRD-era guess) / not numerically estimated in plan | +156 / -0 |
| `README.md` delta | ~10 lines | +22 / -0 |
| `prd.md` delta | 2 edits (OQ#3 + M3 row) | +2 / -1 |

The `setup.sh` delta came in larger than the original PRD's "~20 lines of bash" guess because the plan called for explicit per-distro firewall handling, fail2ban unban-then-stop ordering, sshd unit-name detection mirrored from Step 5, copy-pastable manual fallback when `.bak` is missing, and a confirmation banner that lists exactly what will change. All of that was in the plan; the line count is the cost of doing it properly rather than the minimum hack.

## Tasks Completed

| # | Task | Status | Notes |
|---|---|---|---|
| 1 | Add `--rollback` and `--yes`/`-y` flag parsing | Complete | Mirrors `--clear-state` shape; `ASSUME_YES` exposed as a global for `do_rollback`. |
| 2 | Implement `do_rollback` | Complete | Confirm → recover SSH_PORT → restore `.bak` (or die with manual fallback) → firewall reopen 22/remove custom → fail2ban unban+stop → sshd restart → summary banner. |
| 3 | Branch in `main()` to call rollback | Complete | After `detect_os`; skips prereq install and the 7-step flow. State file left untouched. |
| 4 | Update `--help` | Complete | Aligned `--rollback` and `--yes, -y` lines added. |
| 5 | README "Recovery" subsection | Complete | Placed between Step 7 and License; documents console-access caveat and what is/isn't touched. |
| 6 | Resolve PRD OQ#3 + add Milestone 3 row | Complete | OQ#3 marked resolved with link to plan; M3 row appended with status `in-progress`. |

## Validation Results

| Level | Status | Notes |
|---|---|---|
| L1 `bash -n setup.sh` | Pass | |
| L1 shellcheck | Skipped | Tool not installed; advisory in plan. |
| L1 `--help` flag presence | Pass | `--rollback` and `--yes, -y` both present (verified by grepping help output with the root-check temporarily bypassed since `--help` lives after the EUID gate). |
| L2 Helper presence | Pass | `do_rollback` defined; `main()` branches on `rollback=true` before the 7-step flow. |
| L3 Build | N/A | Single bash script. |
| L4 Integration | Deferred | Requires throwaway VPS smoke per Validation block (happy-path rollback after a full hardened run, missing-`.bak` case, default-N abort). |
| L5 Edge cases | Deferred | Same — manual VPS smoke per supported distro family. |

## Files Changed

| File | Action | Lines |
|---|---|---|
| `setup.sh` | UPDATED | +156 / -0 |
| `README.md` | UPDATED | +22 / -0 |
| `.claude/prds/vps-fortress.prd.md` | UPDATED | +2 / -1 |
| `.claude/plans/vps-fortress-rollback.plan.md` | (already committed in `c7fd4c5`) | — |

Branch: `feat/smooth-pubkey-onboarding`. Commit pending.

## Deviations from Plan
None — implemented exactly as the 6-task plan specified. Two minor implementation choices worth noting (both consistent with the plan's "best-effort" guidance):

- `fail2ban-client unban --all` is run **before** `systemctl stop fail2ban` because the client needs the daemon socket; both are wrapped in `|| true` per the plan's best-effort treatment of an absent service.
- The confirmation banner adapts its wording when no custom port is recorded (omits the "remove `${SSH_PORT}/tcp`" line) so the prompt accurately reflects what's about to happen.

## Issues Encountered
- `shellcheck` not installed locally; skipped per plan's advisory note.
- Script's root check fires before `main()` runs, so the `--help` smoke had to bypass the EUID gate via a one-line `sed` filter on a temp copy. The shipped script is unchanged.

## Tests Written
None — no test harness in the repo. Plan calls for manual VPS smoke; deferred to user.

## Next Steps
- [ ] Manual smoke on a throwaway VPS:
  - Run full hardening, then `sudo bash setup.sh --rollback --yes` from console; verify `ssh user@ip` (port 22) works and `ssh -p <old_port> user@ip` is refused.
  - `sudo bash setup.sh --rollback` without `--yes`: prompt appears, default N aborts cleanly.
  - Remove `/etc/ssh/sshd_config.bak` and re-run with `--yes`: dies with the copy-pastable manual recovery block.
  - Per distro family (apt / dnf / pacman): firewall reopen 22 and remove the custom port both succeed.
- [ ] After smoke passes, flip PRD Milestone 3 status to `complete`.
- [ ] Open PR via `/ecc:prp-pr` (covers M1 + M2 + M3 commits on `feat/smooth-pubkey-onboarding`).
