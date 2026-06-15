# Plan: Smooth Public-Key Onboarding

**Source PRD**: `.claude/prds/vps-fortress.prd.md`
**Selected Milestone**: 1 — Smooth public-key onboarding
**Complexity**: Medium

## Summary
The current `setup.sh` already includes the paste-and-confirm hardening from the stale prior plan: multi-line paste handling, SSH key validation, fingerprint preview, duplicate detection, and safe permissions. The next useful delta is to reduce copy-paste friction by letting users provide a key source such as `gh:<username>` or a public HTTPS URL, while preserving the existing paste flow as the fallback. This keeps the solo-dev UX simple without adding a web UI or orchestration layer.

## Patterns to Mirror
| Category | Source | Pattern |
|---|---|---|
| Naming | `setup.sh:294`, `setup.sh:311`, `setup.sh:344` | Snake_case bash helpers near the step that uses them (`read_pubkey_block`, `validate_pubkey`, `pubkey_fingerprint`). |
| Errors | `setup.sh:24-29`, `setup.sh:382-403` | User-facing failures use `warn`; invalid input reprompts inside a `while true` loop instead of exiting. |
| Logging | `setup.sh:24-28`, `setup.sh:391-394` | Use `info` for instructions/status, `success` after writes, `warn` for recoverable safety issues. |
| Data access | `setup.sh:374-413` | Filesystem writes are explicit: create directory, append only after validation/confirmation, then `chmod` and `chown`. |
| Tests | No test harness present | Use `bash -n setup.sh`; optional `shellcheck setup.sh`; manual smoke on throwaway VPS. |
| Network fallback | `setup.sh:132-135`, `setup.sh:610-613` | Existing code uses `curl`/`git` when package manager paths fail; network-dependent paths should fail clearly and fall back. |

## Files to Change
| File | Action | Why |
|---|---|---|
| `setup.sh` | UPDATE | Add public-key source selection and fetch helpers while preserving the existing paste/validate/preview/write flow. |
| `README.md` | UPDATE | Document that `setup.sh` can accept paste flow and, if implemented, GitHub/URL key sources; keep manual instructions for guide users. |
| `.claude/prds/vps-fortress.prd.md` | UPDATE | Already updated milestone #1 to `in-progress` and linked this plan. |

## Tasks

### Task 1: Add key-source parsing helper
- **Action**: Add a small helper near the existing Step 3 helpers that accepts one of:
  - `paste` or empty input: use the existing paste-and-confirm flow.
  - `gh:<username>`: fetch keys from `https://github.com/<username>.keys`.
  - `url:<https-url>` or raw `https://...`: fetch keys from that URL.
- **Mirror**: Keep helper naming consistent with existing Step 3 helpers (`read_pubkey_block`, `validate_pubkey`).
- **Validate**: `bash -n setup.sh`.

### Task 2: Add safe key fetching helper
- **Action**: Add a helper that fetches candidate keys using `curl -fsSL --max-time 10`. It must:
  - Reject non-HTTPS URLs.
  - Reject empty responses.
  - Reject responses larger than a small cap (e.g. 64 KiB) to avoid accidental huge downloads.
  - Parse line-by-line and keep only lines that pass `validate_pubkey`.
  - Return one or more valid keys for user selection.
- **Mirror**: Recoverable failures should `warn` and return non-zero so the caller can fall back to paste, matching the current Step 3 loop style.
- **Validate**: `bash -n setup.sh`; manual fetch from a known GitHub `.keys` endpoint on a throwaway machine.

### Task 3: Add key selection when multiple keys are fetched
- **Action**: If the fetched source contains multiple valid public keys, show numbered fingerprint previews and ask the user to pick one or all. For v1, prefer a simple single-key selection to avoid surprising writes; `all` can be deferred if it complicates the flow.
- **Mirror**: Reuse `pubkey_fingerprint` for preview and `read -rp` validation loops like the SSH port/user prompts.
- **Validate**: Manual test with a GitHub user that has multiple public keys.

### Task 4: Integrate source selection into `step_3_ssh_key_auth`
- **Action**: At the start of Step 3, ask for key source:
  - `paste` remains the default and calls the current flow unchanged.
  - `gh:<username>` / URL paths fetch, validate, preview, confirm, then reuse the existing duplicate-check/write/permissions block.
- **Mirror**: Do not alter the resume-state contract; `mark_step_completed "step_3"` remains in `main` after the function returns successfully.
- **Validate**: Manual smoke: paste path still works; `gh:<username>` path works; bad URL falls back without writing.

### Task 5: Update README Step 3
- **Action**: Add a short note near Step 3 explaining that `setup.sh` now supports interactive key onboarding via paste and optional remote key source. Keep manual `authorized_keys` instructions intact.
- **Mirror**: README remains a hand-executable guide; avoid turning it into implementation documentation.
- **Validate**: Visual review.

## Validation
```bash
bash -n setup.sh
shellcheck setup.sh || true

# Manual smoke on throwaway VPS:
sudo bash setup.sh --start-step 3 --skip-prereq
# 1. Default paste path: valid key -> preview -> confirm -> writes once, mode 600
# 2. Duplicate paste: warns and does not append duplicate
# 3. Invalid paste: warns and reprompts
# 4. gh:<username>: fetches keys, previews selection, confirms, writes selected key
# 5. Bad URL / non-HTTPS URL: warns, no write, offers paste fallback
```

## Risks
| Risk | Likelihood | Mitigation |
|---|---|---|
| Fetching GitHub/URL keys introduces network dependency | Medium | Keep paste as default and fallback; time out quickly with clear warning. |
| URL source could serve malicious or unexpected content | Medium | HTTPS only, size cap, line-by-line public-key validation, explicit fingerprint confirmation before write. |
| Multiple fetched keys confuse users | Medium | Show numbered fingerprints and require explicit selection; avoid auto-writing all keys in v1. |
| Adding more choices undermines the “simple” differentiator | Medium | Default to paste or a single source prompt; keep wording short and recoverable. |
| Step 3 changes accidentally break existing paste flow | Medium | Preserve current helper behavior and manually smoke-test paste path first. |

## Acceptance
- [ ] Existing paste-and-confirm flow still works unchanged.
- [ ] `gh:<username>` fetches valid keys, previews fingerprints, and writes only after confirmation.
- [ ] HTTPS URL source works with the same validation and confirmation path.
- [ ] Non-HTTPS, empty, oversized, or invalid sources do not write anything and fall back cleanly.
- [ ] `bash -n setup.sh` passes.
- [ ] README Step 3 reflects the script UX without removing manual instructions.
