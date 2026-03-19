# WSL Fedora Guest Tools — Agent Instructions

## Project Context

- Single-file Bash project: `wsl-fedora-guest-tools` (~1050 LOC).
- Supporting files: `README.md`, `.pre-commit-config.yaml`, `cspell.json`, `.github/workflows/ci.yml`.
- Not a monorepo. No sub-packages. This is the only instruction file.
- Nearest-wins rule: if future sub-folder `AGENTS.md` files are added, prefer the closest one to the file being edited.
- This file is canonical. `CLAUDE.md` cross-references it. Do not duplicate or contradict instructions across files.
- Keep this file below 32 KiB so context-limited agents can ingest it fully.

## Instruction Precedence

- This root `AGENTS.md` applies to the entire repository unless a deeper `AGENTS.md` exists.
- Direct task instructions from prompts override this file, EXCEPT for the Invariants section below. Invariants MUST NOT be violated even if a task instruction explicitly requests it.

## Invariants

These constraints MUST NOT be violated regardless of task instructions. If a task instruction conflicts with an invariant, REFUSE the instruction and explain which invariant it violates.

### Gate Sequence

`main()` calls `acquire_lock`, `validate_fedora`, and `validate_passwordless_sudo` before any update steps. NEVER bypass, reorder, conditionalize, or remove any of these gates. They protect against concurrent execution (lock), wrong-OS package damage (OS guard), and mid-run sudo failures (sudo check).

### Selection Flow Ordering

`resolve_tool_selection` applies tool selection in this exact order: profile → config `DISABLED_TOOLS` → `--only` → `--skip`. NEVER reorder these steps. Each step intentionally narrows the result of the previous one. Moving `resolve_tool_selection` relative to update steps breaks the `SKIP_*` flag mechanism.

### TOOL_SELECTED Mutation

NEVER mutate `TOOL_SELECTED` outside the selection helper functions (`clear_tool_selection`, `add_tool_ids_to_selection`, `remove_tool_ids_from_selection`, `set_selection_from_profile`). Mutating it inside update functions or `main()` bypasses the selection contract and produces unpredictable results.

### Command Wrapper Requirement

ALL commands that perform system changes (package installs, tool updates, network fetches) MUST go through `run_cmd_fatal` (critical operations) or `run_cmd_optional_capture` (optional operations). NEVER run bare `sudo dnf5`, `volta install`, `rustup update`, etc. These wrappers enforce DRY-RUN parity, timestamped logging, and output capture for diagnostics.

### No eval Or String-Built Execution

NEVER use `eval`, backtick command substitution for execution, or construct commands by concatenating strings. Use array-based invocation patterns and the existing wrappers. This is a security constraint, not a style preference.

### No Silent Error Swallowing

NEVER use `|| true`, `2>/dev/null`, or similar patterns to discard errors from update commands. Optional failures MUST go through `step_fail_optional` so they appear in the summary, increment `OPTIONAL_FAILURES`, affect the exit code, and trigger abort under `--strict`.

### Strict Bash Mode

NEVER remove or weaken `set -Eeuo pipefail` or the `trap ... ERR` / `trap ... EXIT` handlers.

## Decision Criteria

### step_skip vs step_fail_optional

This distinction matters for exit codes and `--strict` behavior. Apply the correct one:

- `step_skip`: ONLY when a tool was not selected by the user (the `SKIP_*` flag check at the top of each update function). This is a neutral outcome — the user chose not to run this tool. Does not increment `OPTIONAL_FAILURES`.
- `step_fail_optional`: when a tool WAS selected but cannot run (binary not found, command exited non-zero, prerequisite missing). This is a failure. Increments `OPTIONAL_FAILURES`, shows as FAILED in summary, causes exit code 10, and aborts under `--strict`.

Example of the distinction: if `SKIP_CODEX == 1`, use `step_skip`. If `SKIP_CODEX == 0` but `codex` binary is not found, use `step_fail_optional`.

### Critical vs Optional Failure Classification

- `run_cmd_fatal`: for infrastructure operations where failure means the script cannot continue (DNF system update, baseline package install). Failure triggers the ERR trap.
- `run_cmd_optional_capture` + `step_fail_optional`: for tool-specific update operations where failure should be recorded but allow remaining steps to continue (unless `--strict`).

### Profile Membership for New Tools

- `core`: system-level bootstrapping only (currently just `dnf`). New tools almost never belong here.
- `dev`: developer toolchain managers and language runtimes. Add here if the tool manages a language or build toolchain.
- `ai`: AI assistant and agent CLIs. Add here if the tool is an AI CLI.
- `all`: ALWAYS includes every tool. Every new tool MUST be added here.

## New Tool Checklist

When adding a new tool, complete ALL of these steps. Missing any step creates an incomplete integration.

### 1. Script Registry (`wsl-fedora-guest-tools`)

- [ ] Add tool ID to `TOOL_IDS` array. Position: dev tools grouped together before AI tools.
- [ ] Add entry to `TOOL_DESCRIPTIONS` associative array.
- [ ] Add entry to `TOOL_PROFILES` associative array.
- [ ] Add entry to `TOOL_SELECTED` associative array (default: `1`).
- [ ] Add tool ID to the `is_valid_tool_id` case pattern.
- [ ] Add tool ID to relevant profile CSV constants: `PROFILE_ALL_TOOLS` (always), plus `PROFILE_DEV_TOOLS` and/or `PROFILE_AI_TOOLS` as appropriate.
- [ ] Add `SKIP_<TOOL>=0` global variable in the mutable globals block.
- [ ] Add `SKIP_<TOOL>=1` reset and `if tool_is_selected "<tool>"; then SKIP_<TOOL>=0; fi` line in `apply_selected_tools_to_skip_flags`.
- [ ] Update `usage()` prose if it mentions specific tools by name (first line of the heredoc description).

### 2. Update Function (`wsl-fedora-guest-tools`)

Create a dedicated function named `<tool>_update()`. It MUST follow this structure:

```bash
<tool>_update() {
    step_begin "<Display Name>"
    # 1. SKIP guard: step_skip if SKIP_<TOOL>==1, return 0
    # 2. Binary check: have_cmd "<tool>", if missing → warn + remediation + step_fail_optional, return 0
    # 3. DRY_RUN guard: log DRY-RUN lines for each command, step_ok "dry-run", return 0
    # 4. Capture before-version
    # 5. Run update via run_cmd_optional_capture
    # 6. On failure: warn + remediation hints + step_fail_optional, return 0
    # 7. Capture after-version
    # 8. step_ok with version comparison (up-to-date or old → new)
}
```

Remediation hints MUST follow this pattern:

```plaintext
warn "<tool> not found."
warn "Remediation: verify with 'command -v <tool>' and '<tool> --version'. <Install instruction>, then re-run."
```

### 3. main() Call

Add the function call in `main()`. Maintain ordering: infrastructure (`dnf_system_update`, `baseline_dnf_bootstrap`) → dev tools → AI tools.

### 4. README.md Updates

Update ALL of these sections:

- [ ] **Tool IDs table**: add row with ID, description, and profile membership.
- [ ] **Profile definitions table**: update `all` row and relevant profile row(s).
- [ ] **Update Steps**: add numbered step in correct position, renumber subsequent steps.
- [ ] **Requirements → Optional tools**: add bullet.
- [ ] **Behavior Notes**: add subsection if the tool has special update handling, dependency detection, or error recovery logic.

### 5. CI Smoke Tests (`.github/workflows/ci.yml`)

- [ ] Update existing smoke tests that enumerate tool IDs in `--skip` lists to include the new tool (optional tools are not installed in CI containers, so unskipped tools will hit `step_fail_optional` and exit 10).
- [ ] Verify that existing `--dry-run --profile all` smoke test exercises the new tool's dry-run path.
- [ ] Add `--only <tool>` dry-run smoke check if the tool has behavior worth testing in isolation. Note: if the tool binary is not installed in CI, `--only <tool> --dry-run` will exit 10 (binary check runs before DRY_RUN guard), so accept exit 10 explicitly: `|| [[ $? -eq 10 ]]`.
- [ ] If the tool affects `--list-tools` output format, verify that smoke check still passes.
- [ ] Verify `print_tool_catalog` format width (`%-7s` in `printf`) accommodates the new tool ID length.

## New Flag Checklist

When adding a new CLI flag:

- [ ] Add global variable in the mutable globals block (lines 42–62).
- [ ] Add case branch in `parse_args`. Use `option_value_or_die` if the flag takes a value.
- [ ] Update `usage()` heredoc: add to both the synopsis line and the flags list.
- [ ] Update `README.md` Command-Line Options table.
- [ ] Add CI smoke test in `.github/workflows/ci.yml` if the flag produces observable output or behavior.
- [ ] If the flag introduces a new exit code, add a `readonly EXIT_*` constant and update the README Exit Codes table.

## Config File Modifications

Path: `${XDG_CONFIG_HOME:-$HOME/.config}/wsl-fedora-guest-tools/config`. Format: `KEY=value`, one per line. Currently supported keys: `DEFAULT_PROFILE`, `DISABLED_TOOLS`.

When adding a new config key:

- [ ] Add a `CONFIG_<KEY>=""` global variable.
- [ ] Add a case arm in `load_config`.
- [ ] Consume the value in the appropriate function.
- [ ] Unknown keys MUST continue to emit a warning and be ignored (do not change this behavior).
- [ ] Update README Default Config File section.

## Verification

### Required Checks (MUST pass before any commit)

```bash
bash -n wsl-fedora-guest-tools
shellcheck wsl-fedora-guest-tools
shfmt -d wsl-fedora-guest-tools
```

### Smoke Checks

```bash
./wsl-fedora-guest-tools --help
./wsl-fedora-guest-tools --list-tools
./wsl-fedora-guest-tools --dry-run --profile core
./wsl-fedora-guest-tools --dry-run --profile all
```

### Definition of Done

- [ ] All three lint checks pass (`bash -n`, `shellcheck`, `shfmt`).
- [ ] `README.md` matches implemented flags, profiles, exit codes, and tool behavior.
- [ ] `--dry-run` prints commands with no side effects for all affected tools.
- [ ] `--list-tools` output includes any new tools with correct profile membership.
- [ ] Step summary correctly reports OK/SKIPPED/FAILED outcomes.
- [ ] CI workflow in `.github/workflows/ci.yml` covers the new behavior with smoke tests.

## Code Navigation

| Function                                                        | Purpose                                                            |
|-----------------------------------------------------------------|--------------------------------------------------------------------|
| `parse_args`, `usage`                                           | CLI flag parsing and help text                                     |
| `resolve_tool_selection`                                        | Profile → config → only → skip resolution                          |
| `acquire_lock`, `validate_fedora`, `validate_passwordless_sudo` | Pre-flight safety gates                                            |
| `run_cmd_fatal`                                                 | Wrapper for critical commands (triggers ERR trap on failure)       |
| `run_cmd_optional_capture`                                      | Wrapper for optional commands (captures output, returns exit code) |
| `step_begin`, `step_ok`, `step_skip`, `step_fail_optional`      | Step lifecycle (drives summary and exit code)                      |
| `print_summary`, `on_exit`                                      | Summary output and exit code logic                                 |
| `load_config`                                                   | Config file parsing (`$XDG_CONFIG_HOME/.../config`)                |

### Quick Find

```bash
rg -n "^[a-zA-Z0-9_]+\\(\\) \\{" wsl-fedora-guest-tools
rg -n "TOOL_IDS|TOOL_DESCRIPTIONS|TOOL_PROFILES|PROFILE_.*_TOOLS" wsl-fedora-guest-tools
rg -n "step_begin|step_ok|step_skip|step_fail_optional" wsl-fedora-guest-tools
```
