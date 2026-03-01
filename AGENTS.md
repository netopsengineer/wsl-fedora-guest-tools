# WSL Fedora Guest Tools

## Project Snapshot

- Repository type: simple single-package repo (not a monorepo/workspace).
- Primary code lives in `wsl-fedora-guest-tools.sh` (Bash, ~1.1k LOC).
- Supporting files are `README.md`, `.pre-commit-config.yaml`, and `cspell.json`.
- This root file is intentionally lightweight; there are currently no sub-folder `AGENTS.md` files because no major sub-packages exist.
- Nearest-wins rule: if future sub-folder `AGENTS.md` files are added, prefer the closest one to the file being edited.

## Instruction Scope And Precedence

- This root `AGENTS.md` applies to the entire repository unless a deeper `AGENTS.md` exists.
- If multiple `AGENTS.md` files apply, follow the one nearest to each edited file.
- Direct task instructions from system/developer/user prompts override `AGENTS.md`.
- If one change touches files under different instruction scopes, apply the nearest instructions per file.

## Repository Map

- Main script: `wsl-fedora-guest-tools.sh`
- User documentation: `README.md`
- Lint/format hooks: `.pre-commit-config.yaml`
- Spelling allowlist: `cspell.json`

## Instruction File Hygiene

- Keep this file concise and task-oriented; target roughly two pages and link out for deep context.
- Keep guidance explicit, objective, and testable; avoid vague or aspirational wording.
- Keep this file comfortably below 32 KiB so Codex-class agents can reliably ingest it end-to-end.
- Avoid duplicating competing instructions across files. If adding `.github/copilot-instructions.md` or `CLAUDE.md`, keep this file canonical and cross-reference it.

## Root Setup Commands

```bash
# Optional local tooling
sudo dnf install -y shellcheck shfmt pre-commit ripgrep

# Static checks
bash -n wsl-fedora-guest-tools.sh
shellcheck wsl-fedora-guest-tools.sh
shfmt -d wsl-fedora-guest-tools.sh
pre-commit run --all-files

# Safe smoke checks (no package changes)
./wsl-fedora-guest-tools.sh --help
./wsl-fedora-guest-tools.sh --list-tools
./wsl-fedora-guest-tools.sh --dry-run --profile core
```

## Universal Conventions

- Keep strict Bash mode and traps intact: `set -Eeuo pipefail`, `trap ... ERR`, `trap ... EXIT`.
- Preserve command execution wrappers:
  - Critical operations must go through `run_cmd_fatal`.
  - Optional operations should go through `run_cmd_optional_capture` and `step_fail_optional`.
- Preserve selection flow in `resolve_tool_selection`: profile -> config disabled -> `--only` -> `--skip`.
- Keep step lifecycle consistent (`step_begin`, `step_ok`, `step_skip`, `step_fail_optional`) so summary output remains accurate.
- Maintain idempotency: re-running should be safe and should not force unnecessary reinstall/update work.
- Default to `--dry-run` for validation and smoke checks; run non-dry-run package changes only when explicitly requested.
- Update `README.md` whenever flags, profile behavior, exit codes, or tool support changes.

## Patterns And Conventions

- DO follow existing tool registry patterns in `wsl-fedora-guest-tools.sh`:
  - Add tool ID metadata in `TOOL_IDS`, `TOOL_DESCRIPTIONS`, and `TOOL_PROFILES`.
  - Extend profile CSV constants if the tool belongs to a profile.
- DO implement each tool step as a dedicated function with the `_update` or task naming used in the script, then call it from `main`.
- DO use existing helpers for normalization and validation (`trim_ws`, `to_lower`, `filter_tool_ids`, `is_valid_tool_id`).
- DO model user-facing remediation hints after existing patterns in `volta_node_update`, `uv_update`, `claude_update`, and `codex_update`.
- DON'T bypass the lock/OS/sudo gate sequence (`acquire_lock`, `validate_fedora`, `validate_passwordless_sudo`) in `main`.
- DON'T mutate `TOOL_SELECTED` ad hoc outside selection helpers unless there is a clear reason and matching tests/checks.
- DON'T run direct package-manager commands in new logic without logging/DRY-RUN parity through the command wrappers.
- DON'T add broad, silent error swallowing; optional failure handling should still report detail in the summary.

## Security & Secrets

- Never commit tokens, credentials, or machine-specific secrets.
- Treat privileged commands carefully: all `sudo` operations should remain explicit and reviewable.
- Avoid `eval` and string-built shell execution; prefer array-safe command invocation patterns.
- Keep config parsing strict and explicit; unknown keys should continue to warn and be ignored.

## JIT Index

### Code Navigation

- Argument parsing and CLI contract: `parse_args`, `usage`
- Tool/profile resolution: `resolve_tool_selection`
- Lock and environment guards: `acquire_lock`, `validate_fedora`, `validate_passwordless_sudo`
- Command execution wrappers: `run_cmd_fatal`, `run_cmd_optional_capture`
- Update steps:
  - `dnf_system_update`
  - `baseline_dnf_bootstrap`
  - `volta_node_update`
  - `uv_update`
  - `claude_update`
  - `codex_update`
- Summary/exit behavior: `print_summary`, `on_exit`

### Quick Find Commands

```bash
# List all Bash functions
rg -n "^[a-zA-Z0-9_]+\\(\\) \\{" wsl-fedora-guest-tools.sh

# Jump to update steps
rg -n "^(dnf_system_update|baseline_dnf_bootstrap|volta_node_update|uv_update|claude_update|codex_update)\\(\\)" wsl-fedora-guest-tools.sh

# Find tool registry and profile definitions
rg -n "TOOL_IDS|TOOL_DESCRIPTIONS|TOOL_PROFILES|PROFILE_.*_TOOLS" wsl-fedora-guest-tools.sh

# Find step status and summary flow
rg -n "step_begin|step_ok|step_skip|step_fail_optional|print_summary|on_exit" wsl-fedora-guest-tools.sh

# Find docs for CLI flags and behavior
rg -n "Command-Line Options|Tool IDs and Profiles|Selection Precedence|Exit Codes" README.md
```

## Testing Guidance

- There is no dedicated unit test suite in this repository today.
- Minimum verification for behavior changes:
  - `bash -n wsl-fedora-guest-tools.sh`
  - `shellcheck wsl-fedora-guest-tools.sh`
  - `shfmt -d wsl-fedora-guest-tools.sh`
  - Dry-run scenarios from `README.md` (`--profile`, `--only`, `--skip`)

## Definition of Done

- Script syntax, ShellCheck, and format checks pass.
- `README.md` matches implemented flags/profiles/exit behavior.
- Dry-run mode still prints commands with no side effects.
- Step summary correctly reports OK/SKIPPED/FAILED outcomes and optional-failure exit semantics.
