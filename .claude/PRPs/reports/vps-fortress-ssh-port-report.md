# Implementation Report: Resolve SSH Port Strategy

## Summary
Replaced the static `2222` default in Step 4 of `setup.sh` with a freshly randomized port in `[10000, 65535]`. The interactive prompt is preserved per user direction — only its default value changes. Added a `--ssh-port=N` (`-p N`) flag for non-interactive runs that skips the prompt entirely.

## Assessment vs Reality

| Metric | Predicted (Plan) | Actual |
|---|---|---|
| Complexity | Small | Small |
| Files Changed | 3 | 3 (+1 plan artifact) |
| Lines | ~30–50 in setup.sh | +78 / -14 in setup.sh |

## Tasks Completed

| # | Task | Status | Notes |
|---|---|---|---|
| 1 | Add `--ssh-port` flag parsing in `main()` | Complete | Validates 1024..65535 at parse time. |
| 2 | Add `pick_random_ssh_port` helper | Complete | shuf with awk fallback; ss collision check. |
| 3 | Wire flag/random default into `step_4_harden_ssh` | Complete | Flag wins; otherwise prompt with random default. |
| 4 | Update `--help` output | Complete | New flag listed in aligned block. |
| 5 | Update README Step 4 | Complete | One-paragraph note added. |
| 6 | Flip PRD Milestone 2 status | Complete | `pending` → `in-progress`; linked to plan. |

## Validation Results

| Level | Status | Notes |
|---|---|---|
| L1 Syntax (`bash -n`) | Pass | |
| L1 shellcheck | Skipped | Tool not installed; plan listed as advisory. |
| L2 Helper range check | Pass | Helper isolated and run; output in `[10000, 65535]`. |
| L1 Flag rejection smoke | Inspected | Script's root-check predates `main()`, so non-root invocations short-circuit before flag parsing. Code path verified by inspection; manual `sudo` smoke deferred to throwaway-VPS testing. |
| L3 Build / L4 Integration | N/A | Single bash script; no build system. |

## Files Changed

| File | Action | Lines |
|---|---|---|
| `setup.sh` | UPDATED | +78 / -14 |
| `README.md` | UPDATED | +2 / -0 |
| `.claude/prds/vps-fortress.prd.md` | UPDATED | +1 / -1 |
| `.claude/plans/vps-fortress-ssh-port.plan.md` | CREATED | +97 |

## Deviations from Plan
None — implemented exactly as planned.

## Issues Encountered
- `shellcheck` not installed locally; skipped (plan marked it advisory).
- Script's root check fires before flag parsing, so unprivileged smoke tests can't reach the parse-time validator. Confirmed correctness by code inspection; sudo smoke is part of the plan's manual validation list.

## Tests Written
None — no test harness exists for this bash script. Plan calls for manual smoke testing on throwaway VPSes per supported distro family; that step is deferred to the user.

## Next Steps
- [ ] Manual smoke test on throwaway VPSes (apt / dnf / pacman):
  - No-flag run: prompt shows random default, Enter accepts, SSH login on chosen port works.
  - `--ssh-port=2222`: honored, prompt skipped.
  - `--ssh-port=80` / `--ssh-port=abc`: exit 1.
  - `--start-step 4 --resume`: prior port restored.
- [ ] After smoke passes, update PRD Milestone 2 status to `complete`.
- [ ] Open PR via `/ecc:prp-pr` (covers both M1 and M2 commits on `feat/smooth-pubkey-onboarding`).
