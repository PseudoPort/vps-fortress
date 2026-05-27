# vps-fortress

## Problem
Solo developers spinning up new Linux VPSes routinely skip baseline hardening. A freshly provisioned server is exposed to the public internet within minutes — automated bots scan, brute-force, and attempt logins continuously — yet hardening steps (non-root user, SSH key auth, custom port, firewall, Fail2Ban) are perceived as tedious enough to defer "until later," which often means never. The cost is a non-trivial chance of compromise plus a recurring time tax of re-doing the same checklist on every new server.

## Evidence
- Author's firsthand experience operating personal VPSes: suspicious authentication logs, repeated automated login attempts, and DDoS activity observed against own servers.
- *Assumption — needs broader validation via informal poll (r/selfhosted, HN) or surveying compromised-VPS post-mortems to confirm the behavior generalizes beyond the author. n=1 today.*

## Users
- **Primary**: Solo developers provisioning a fresh Linux VPS (Ubuntu, Debian, RHEL family, Arch) for a side project, personal service, or small production workload. Comfortable with the shell, want a one-shot tool simpler than reading a 7-step guide or learning Ansible.
- **Not for**: Teams managing fleets via configuration management (Ansible/Terraform/Chef); operators with bespoke compliance requirements (PCI, HIPAA, CIS audit); users wanting a GUI/TUI; Windows Server operators.

## Hypothesis
We believe **a single interactive bash script that automates the 7 baseline hardening steps with safe defaults and a smooth public-key onboarding flow** will **close the "I'll harden it later" gap** for **solo developers spinning up new VPSes**.

We'll know we're right when **a fresh VPS goes from provisioned to fully hardened (all 7 steps complete, verified second-terminal SSH login, Fail2Ban active) in a single uninterrupted script run, on a clean install of each supported distro family — confirmed via manual smoke tests by the author.**

*Note: this is a build-time completion metric, not an adoption metric. Adoption signal (GitHub stars, "saved my server" feedback, reduced failed-login attempts) is captured in Open Questions for post-launch validation.*

## Success Metrics
| Metric | Target | How measured |
|---|---|---|
| End-to-end completion on fresh VPS | All 7 steps complete in one run, no manual intervention | Manual smoke test on a fresh VPS per supported distro family |
| Distro coverage | Apt (Ubuntu/Debian), dnf (RHEL/Alma/Rocky/OpenCloudOS), pacman (Arch/Manjaro) all pass smoke test | Manual smoke test |
| Public-key onboarding friction | User completes SSH key setup without leaving the script or hand-editing files on the server | Manual UX walkthrough |
| Adoption signal (post-launch) | TBD — see Open Questions | TBD |

## Scope

**MVP** — Ship the existing `setup.sh` (7 steps, 3 distro families, resume state, Fail2Ban with race-condition fix) plus **one UX delta**: improve the public-key onboarding flow. The current "paste your public key into the prompt" works but is rough — typos and line wrapping cause failures, and a botched key bricks the server once `PasswordAuthentication no` lands. The MVP smooths this single gap. Specific mechanism (guided `ssh-copy-id` instructions, fetch from `https://github.com/<user>.keys`, fetch from URL, or improved paste validation) is decided in `/plan`.

Everything else in the current script ships as-is for v1.

**Out of scope** (explicit, even if requested)
- Web UI / dashboard — kept simple is the differentiator; any UI is a different product.
- Application-layer hardening (nginx, Docker/container, database, TLS/Let's Encrypt, reverse proxy) — out of the "baseline OS hardening" charter.
- Multi-server orchestration (Ansible-style fleet, inventory, parallel runs) — solo-dev tool, not a control plane.
- Windows Server / BSD support — Linux only.
- Rollback / undo — *flagged as a footgun*: a bricked server is the worst-case outcome of this script. Kept out for v1 to preserve scope, but see Open Questions; the existing "verify in second terminal before committing" gate is the v1 mitigation.
- Compliance frameworks (CIS, PCI-DSS, HIPAA mappings) — different audience.
- Kernel sysctl tuning, AppArmor/SELinux policy authoring, AIDE/OSSEC/Wazuh — beyond the 7-step baseline.

## Delivery Milestones
<!-- Business outcomes, not engineering tasks. /plan turns each into a plan. -->
<!-- Status: pending | in-progress | complete -->

| # | Milestone | Outcome | Status | Plan |
|---|---|---|---|---|
| 1 | Smooth public-key onboarding | A solo developer gets their public key onto the new server during the script run without typos, line-wrap failures, or aborting to a second terminal — and a malformed key cannot brick the server. | in-progress | `.claude/plans/vps-fortress.plan.md` |
| 2 | Resolve SSH port strategy | A solo developer running with no flags gets a non-default SSH port without having to think about it; power users can still pin a specific port. | pending | — |

## Open Questions
- [ ] **SSH port: prompt, randomize, or both?** Current script prompts (default 2222). Randomizing by default removes a decision point and matches the "simpler" differentiator. Devil's-advocate default: **randomize in [10000–65535] by default, accept `--ssh-port=N` to override, drop the interactive prompt.** Confirm in `/plan` before implementing.
- [ ] **Public-key onboarding mechanism.** Candidates: (a) keep paste flow but harden validation/preview (already partially done), (b) add `gh:<username>` shortcut that fetches `https://github.com/<username>.keys`, (c) accept arbitrary URL, (d) print copy-paste-ready `ssh-copy-id` instructions and pause. Pick one (or two with a fallback) in `/plan`.
- [ ] **Rollback / safety net.** Out of scope for v1, but the failure mode (locked-out user on a $5 droplet) is severe. Worth ~20 lines of bash to add `setup.sh --rollback` that restores `sshd_config.bak`, reopens port 22, re-enables password auth? Decide before v2.
- [ ] **Adoption metric.** Build-time completion proves "it works"; it doesn't prove "people use it." Pick one post-launch signal: GitHub stars, self-reported completions via opt-in postrun ping, or qualitative reports. Decide before launch.
- [ ] **Evidence is n=1 (author).** Worth a low-effort validation pass (one r/selfhosted thread, a HN Show post) before heavy investment beyond MVP.

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Malformed/wrong public key locks user out after `PasswordAuthentication no` | Medium | High — bricks the server | Preserve and emphasize the existing "verify SSH from a second terminal before committing" gate; harden key validation in the UX delta milestone |
| UX changes regress current working flow | Low | Medium | Smoke-test on each supported distro family before merge; keep paste flow as a fallback path |
| Randomized SSH port collides with a service the user planned to run | Low | Low | Pick from a high range (10000+); offer `--ssh-port=N` override |
| Author-only evidence doesn't generalize | Low | Medium | Treat v1 as a validation experiment; watch issues/stars after launch |
| No rollback path means a single failed run can brick a fresh VPS | Medium | High | Second-terminal verification gate before destructive SSH changes; revisit rollback in v2 (see Open Questions) |
| Bash-only constrains future portability and testability | Low | Low | Acceptable for solo-dev audience; revisit only if MVP succeeds and complexity outgrows bash |

---
*Status: DRAFT — requirements only. Implementation planning pending via /plan.*
