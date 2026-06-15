# Plan: Resolve SSH Port Strategy

**Source PRD**: `.claude/prds/vps-fortress.prd.md`
**Selected Milestone**: 2 — Resolve SSH port strategy
**Complexity**: Small

## Summary
A solo developer running `setup.sh` with no flags should get a non-default SSH port without having to think about it, while power users can still pin a specific port. The interactive prompt in Step 4 is **kept** as the friendly path, but its default changes from the static `2222` to a freshly randomized port in `[10000, 65535]`. A new `--ssh-port=N` flag lets non-interactive runs (CI, automation, repeat hardening) skip the prompt entirely.

## Patterns to Mirror
| Category | Source | Pattern |
|---|---|---|
| Flag parsing | `setup.sh:1016-1058` | `while [[ $# -gt 0 ]]` + `case "$1" in` + `shift`. Mirror the `--start-step|-s` shape for the new flag. |
| Validation | `setup.sh:572-580` | Numeric + range check `1024..65535`; on bad input, `warn` and re-prompt inside `while true`. Mirror exactly so prompt and flag share rules. |
| Helpers | `setup.sh:294`, `setup.sh:344`, `setup.sh:386` | Snake_case helpers placed near the step that uses them; they `warn` on recoverable failures and return non-zero. |
| Persisted state | `setup.sh:1116-1125` | `mark_step_completed "step_4" "$SSH_PORT"` writes; resume restores via `get_step_info "step_4"`. Contract preserved. |
| Logging | `setup.sh:24-28`, `setup.sh:597-609` | `info` for what's about to happen, `success` after the change. |
| Help text | `setup.sh:1031-1049` | Aligned `--flag, -short  Description` block; new flag goes in the same shape. |
| Tests | none | `bash -n setup.sh`; `shellcheck setup.sh` advisory; manual smoke per distro family. |

## Files to Change
| File | Action | Why |
|---|---|---|
| `setup.sh` | UPDATE | Add `--ssh-port` flag, port-pick helper, change Step 4 prompt default to a fresh random port. |
| `README.md` | UPDATE | Document randomized default and `--ssh-port` override; keep the manual `Port 2222` example for guide users. |
| `.claude/prds/vps-fortress.prd.md` | UPDATE | Flip Milestone 2 row from `pending` to `in-progress` and link this plan path. |

## Tasks

### Task 1: Add `--ssh-port` flag parsing in `main()`
- **Action**: Extend the arg loop at `setup.sh:1016-1058` to accept `--ssh-port=N`, `--ssh-port N`, and `-p N`. Validate `1024..65535` immediately; on bad value, `error` + `exit 1` (don't fall through to prompt — bad CLI input should be loud). Store result in a script-scope `SSH_PORT_FLAG`.
- **Mirror**: Match the `--start-step|-s` style for two-arg form and reuse the same regex `^[0-9]+$` + range guard from `step_4_harden_ssh`.
- **Validate**: `bash -n setup.sh`; `bash setup.sh --ssh-port=999` exits 1 with a clear message; `--ssh-port=22000` parses cleanly.

### Task 2: Add `pick_random_ssh_port` helper
- **Action**: Place near other Step-4 helpers. Logic:
  1. Use `shuf -i 10000-65535 -n 1` if available; fall back to `awk -v min=10000 -v max=65535 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'`.
  2. Best-effort collision avoidance: if `ss -ltn` is available and the port is currently listening locally, retry up to 5 times. If still colliding, return the last pick anyway and let the user override via the prompt.
- **Mirror**: Snake_case naming, `warn` on the unlikely retry-exhaustion path, no `die` (the prompt is the safety net).
- **Validate**: `bash -n setup.sh`; run helper in a subshell several times; verify all picks are in range.

### Task 3: Change Step 4 prompt default to randomized port (keep prompt)
- **Action**: At `setup.sh:572-580`, before the `while true` loop:
  - If `SSH_PORT_FLAG` is non-empty → `SSH_PORT="$SSH_PORT_FLAG"`; emit `info "Using SSH port ${SSH_PORT} (from --ssh-port)"`; skip the prompt.
  - Else → call `local default_port; default_port="$(pick_random_ssh_port)"`; change the prompt text from `[default: 2222]` to `[default: ${default_port}]`; the existing `SSH_PORT="${SSH_PORT:-$default_port}"` substitution does the rest. The validation loop is unchanged.
- **Mirror**: Keep the existing validation loop verbatim so flag-supplied and prompt-supplied ports go through identical range checks. Resume contract is unchanged because `mark_step_completed "step_4" "$SSH_PORT"` already persists whatever was chosen.
- **Validate**: `bash -n setup.sh`; manual smoke shows the prompt with a random default; pressing Enter accepts it; typing a custom port still works.

### Task 4: Update `--help` output
- **Action**: Add an aligned `--ssh-port, -p N    Set custom SSH port (1024-65535); skips the prompt` line in the `--help` block at `setup.sh:1031-1049`.
- **Mirror**: Match column alignment of existing flag descriptions.
- **Validate**: `bash setup.sh --help` shows the new flag.

### Task 5: Update README Step 4
- **Action**: Add a single short paragraph near Step 4 noting that `setup.sh` randomizes the SSH port by default (the prompt's default is freshly generated each run) and `--ssh-port=N` pins a specific port for non-interactive runs. Leave the by-hand `Port 2222` example in the manual walkthrough intact.
- **Mirror**: README stays a hand-executable guide; only annotate script behavior in one paragraph, do not rewrite the section.
- **Validate**: Visual review.

### Task 6: Flip PRD Milestone 2 status
- **Action**: In `.claude/prds/vps-fortress.prd.md` at line 51, change row `| 2 | ... | pending | — |` to `| 2 | ... | in-progress | `.claude/plans/vps-fortress-ssh-port.plan.md` |`.
- **Mirror**: Same shape as the Milestone 1 row already filled in.
- **Validate**: Visual review of the PRD's Delivery Milestones table.

## Validation
```bash
bash -n setup.sh
shellcheck setup.sh || true
bash setup.sh --help | grep -- '--ssh-port'

# Manual smoke per distro family on a throwaway VPS:
sudo bash setup.sh                          # prompt shows a random default; Enter accepts
sudo bash setup.sh --ssh-port=2222          # honored, no prompt
sudo bash setup.sh --ssh-port=80            # exit 1 with clear error
sudo bash setup.sh --ssh-port=abc           # exit 1 with clear error
sudo bash setup.sh --start-step 4 --resume  # restores prior port from state file
```

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Random port collides with a service the user plans to run | Low | Low | High range (10000+); prompt lets the user retype any port; `--ssh-port=N` override. |
| `shuf` absent on a minimal image | Low | Low | `awk`+`rand()` fallback; both are universal on the target distros. |
| `ss` absent so collision check is skipped | Low | Low | Helper degrades to single pick; the prompt is still the safety net. |
| Prompt's changing default surprises returning users | Low | Low | README documents the behavior; prompt always echoes the default in brackets. |
| Bad `--ssh-port` value fails after Step 1–3 already ran | Medium | Low | Validate at parse time in `main()` before any step runs. |
| `--resume` reads a stale port that no longer matches sshd | Low | Medium | Existing state contract handles this; smoke case covers it. |

## Acceptance
- [ ] No-flag run shows a randomized default in the Step 4 prompt; pressing Enter accepts it.
- [ ] User can still type a custom port at the prompt and have it validated as before.
- [ ] `--ssh-port=N` skips the prompt and uses N (validated).
- [ ] Invalid `--ssh-port` values exit 1 before any step runs.
- [ ] `--help` lists the new flag.
- [ ] Resume run restores the previously persisted port unchanged.
- [ ] `bash -n setup.sh` passes; `shellcheck` produces no new errors.
- [ ] README Step 4 reflects the new default behavior without removing the manual walkthrough.
- [ ] PRD Milestone 2 row is flipped to `in-progress` and linked to this plan.
