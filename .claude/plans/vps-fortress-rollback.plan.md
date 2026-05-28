# Plan: `--rollback` Recovery Flag

**Source PRD**: `.claude/prds/vps-fortress.prd.md` (resolves Open Question #3; new Milestone 3 row)
**Selected Milestone**: 3 — Rollback safety net
**Complexity**: Small

## Summary
Add `setup.sh --rollback` so a solo developer with **console/serial access** (DigitalOcean droplet console, EC2 system console, hypervisor TTY) can undo the SSH-locking changes from a botched run in one shot. Restores `sshd_config.bak`, reopens port 22, removes the custom port from the firewall, stops Fail2Ban, and restarts sshd. Leaves the new user account, packages, and Step 7 auto-updates intact — those aren't the bricking risk.

This does **not** rescue a session whose only access is SSH on the broken port; the PRD already accepts that constraint via the second-terminal verification gate. Rollback just makes the *recoverable* cases recoverable in <20 seconds.

## Patterns to Mirror
| Category | Source | Pattern |
|---|---|---|
| Flag parsing | `setup.sh:1057-1102` | `case "$1" in --rollback) ROLLBACK=true ;;`; matches `--clear-state` shape. |
| Confirmation prompt | `setup.sh:64-77` | `read -rp "...? [y/N]: "` with default-`N`; rollback is destructive-ish so default-no. |
| State read | `setup.sh:44-49` | Reuse `get_step_info "step_4"` to recover `SSH_PORT` before touching firewall. |
| Firewall add (UFW) | `setup.sh:625-628`, `setup.sh:651-657` | `ufw allow 22/tcp`, optional `ufw delete allow $SSH_PORT/tcp`. |
| Firewall add (firewalld) | `setup.sh:638-642` | `firewall-cmd --permanent --add-port=22/tcp` + `--reload`. |
| sshd restart | `setup.sh:663-674` | Reuse the ssh-vs-sshd unit-name detection block verbatim. |
| Logging | `setup.sh:24-28` | `info` / `success` / `warn`; `die` only for impossible states (no `.bak`). |
| Help text | `setup.sh:1075-1093` | One aligned line per flag in the existing block. |
| Tests | none | `bash -n setup.sh`; manual smoke on a throwaway VPS. |

## Files to Change
| File | Action | Why |
|---|---|---|
| `setup.sh` | UPDATE | Add `--rollback` and `--yes` flags, `do_rollback` function, branch in `main()` to call rollback instead of running the 7 steps. |
| `README.md` | UPDATE | Add a "Recovery" subsection after Step 7 documenting the flag and its console-access caveat. |
| `.claude/prds/vps-fortress.prd.md` | UPDATE | Resolve Open Question #3 in place; add Milestone 3 row to Delivery Milestones linking this plan. |

## Tasks

### Task 1: Add `--rollback` and `--yes` flag parsing
- **Action**: In `main()` arg loop (`setup.sh:1057-1102`), accept `--rollback` (sets `ROLLBACK=true`) and `--yes`/`-y` (sets `ASSUME_YES=true`). `--yes` lets users skip the confirmation prompt over a flaky console connection.
- **Mirror**: Same `case` shape as `--clear-state` and `--ssh-port` from M2.
- **Validate**: `bash -n setup.sh`; `bash setup.sh --help` lists both new flags.

### Task 2: Implement `do_rollback`
- **Action**: New function placed near the other top-level step functions (just before `print_summary` is a fine spot). Logic:
  1. **Confirm** unless `ASSUME_YES`: print exactly what will be touched (sshd_config, firewall, fail2ban) and require `y/N`. Default no.
  2. **Recover SSH_PORT** via `get_step_info "step_4"`. If empty, fall back to `SSH_PORT_FLAG` if set; else `info "no recorded SSH port — will not remove a custom port from firewall"`.
  3. **Restore sshd_config**: if `/etc/ssh/sshd_config.bak` exists → `cp -p sshd_config.bak sshd_config`. Print the `.bak` mtime so the user sees which run it's restoring. If `.bak` is missing → `die` with copy-pastable manual recovery (`sed -i 's/^Port .*/Port 22/' /etc/ssh/sshd_config`, `sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' ...`, etc.).
  4. **Firewall**: detect package manager via existing `detect_os`. UFW: `ufw allow 22/tcp` and (if SSH_PORT known and != 22) `ufw delete allow ${SSH_PORT}/tcp`. firewalld: `firewall-cmd --permanent --add-port=22/tcp` + (if known) `--remove-port=${SSH_PORT}/tcp` + `--reload`. Each operation: `|| warn` rather than `die` — best-effort recovery.
  5. **Fail2Ban**: `systemctl stop fail2ban 2>/dev/null || true`; also `fail2ban-client unban --all 2>/dev/null || true` (covers `/usr/bin/` and `/usr/local/bin/`). Don't disable the service; user can re-enable when confident.
  6. **Restart sshd**: copy the unit-name detection from `step_5_configure_firewall:663-674` verbatim (`systemctl restart ssh` / `sshd` / both-with-fallback).
  7. **Print summary**: "SSH listening on port 22 with PasswordAuthentication=yes. Re-run `sudo bash setup.sh` to harden again." Use the same `print_summary`-style banner block.
- **Mirror**: Best-effort failures `warn`, hard failures `die`. Logging via `info`/`success`.
- **Validate**: `bash -n setup.sh`; manual smoke (see Validation).

### Task 3: Branch in `main()` to call rollback
- **Action**: After arg parsing and `detect_os`, if `ROLLBACK=true` → call `do_rollback` and `exit $?`; skip the 7-step flow. State file is **not** auto-cleared; user can pass `--clear-state` separately if they want to fully restart.
- **Mirror**: Same early-exit pattern used by `--help`.
- **Validate**: `bash -n setup.sh`; on a hardened test VM, `sudo bash setup.sh --rollback --yes` restores port 22 and password auth and exits without running steps 1-7.

### Task 4: Update `--help`
- **Action**: Add aligned lines to the existing help block:
  ```
  --rollback           Restore sshd_config.bak, reopen port 22, stop fail2ban
  --yes, -y            Skip confirmation prompts (for --rollback)
  ```
- **Validate**: `bash setup.sh --help | grep -E -- '--rollback|--yes'` shows both.

### Task 5: README "Recovery" subsection
- **Action**: After Step 7 in `README.md`, add ~10 lines:
  - When to use it (botched run, second-terminal verification failed, you have console access).
  - Console-access caveat (SSH-only access can't run this; you need the cloud console / serial / hypervisor TTY).
  - Exact command: `sudo bash setup.sh --rollback`.
  - What it does and what it doesn't (leaves user account, packages, and auto-updates alone).
- **Validate**: visual review.

### Task 6: Resolve PRD Open Question #3 and add Milestone 3 row
- **Action**: In `.claude/prds/vps-fortress.prd.md`:
  - Edit the rollback Open Questions bullet to mark it resolved with a link to this plan.
  - Append a Milestone 3 row to the Delivery Milestones table: "Rollback safety net" → Status `in-progress`, Plan `.claude/plans/vps-fortress-rollback.plan.md`.
- **Validate**: visual review of both edits.

## Validation
```bash
bash -n setup.sh
shellcheck setup.sh || true
bash setup.sh --help | grep -E -- '--rollback|--yes'

# Manual smoke on a throwaway VPS — happy path:
sudo bash setup.sh                                    # finish all 7 steps with random port
ssh -p <port> <user>@<ip>                             # confirm hardened access works
# Now exercise rollback (from console or existing root shell):
sudo bash setup.sh --rollback --yes
ssh <user>@<ip>                                       # password auth + port 22 should work again
ssh -p <port> <user>@<ip>                             # should now FAIL (custom port removed)

# Manual smoke — negative cases:
sudo bash setup.sh --rollback                         # without --yes: prompts, default N aborts
sudo rm /etc/ssh/sshd_config.bak && \
  sudo bash setup.sh --rollback --yes                 # dies with copy-pastable manual instructions
```

## Risks
| Risk | Likelihood | Mitigation |
|---|---|---|
| User runs rollback over SSH on the broken port — can't reach the server | High; **expected** | README documents this is for console access; the prompt itself reminds the user. |
| `.bak` doesn't exist (Step 4 never ran or `.bak` was rotated) | Medium | `die` with copy-pastable manual `sed`/`systemctl` instructions. |
| Firewall command fails (e.g. UFW not active) | Low | Best-effort `warn` per operation; rollback continues so sshd_config restore + restart still happens. |
| Fail2Ban stop fails because not installed | Medium | `|| true`; don't fail rollback over an absent service. |
| `--rollback` accidentally invoked on a healthy box | Low | Confirmation defaults to no; `--yes` is opt-in. |
| Restoring `.bak` brings back stale config that didn't reflect manual edits | Low | Same `.bak` pattern Step 4 already uses; document the limitation in README. |
| Existing connection on the new port is dropped when sshd restarts on port 22 | Low | systemctl restart preserves established connections on most distros; rollback runs from console anyway. |
| State file says step_4 complete but `.bak` predates this run | Low | Rollback uses the *current* `.bak` regardless of state; print the `.bak` mtime so the user sees which run they're restoring. |

## Acceptance
- [ ] `--rollback` flag parses; `--yes` flag parses.
- [ ] `--help` lists both flags.
- [ ] Without `--yes`, rollback prompts and aborts on default N.
- [ ] With `--yes` on a hardened box, rollback restores port 22, password auth, removes the custom port from the firewall, stops fail2ban, and restarts sshd.
- [ ] Without `.bak`, rollback exits with a copy-pastable manual recovery message.
- [ ] Best-effort failures (firewall, fail2ban absent) `warn` and continue rather than aborting.
- [ ] README has a Recovery subsection with the console-access caveat.
- [ ] PRD Open Question #3 marked resolved; Delivery Milestones table has a Milestone 3 row linking this plan.
- [ ] `bash -n setup.sh` passes.
