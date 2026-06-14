# WSL Fedora Guest Tools

A robust bootstrapper and idempotent update utility for Fedora WSL environments. It orchestrates critical system installs and updates via DNF5 alongside optional updates for developer tools and AI CLIs: Volta/Node.js, `uv` (self-update and tool upgrades), GitHub CLI, Claude Code, and Codex.

## Why

Developer tooling and AI CLIs change frequently. Keeping everything current often resolves issues quickly and unlocks new features. On macOS, `brew update && brew upgrade` makes this easy. This project provides a similarly reliable workflow for Fedora on WSL.

## Features

- **System Updates**: Safe DNF5-based system package upgrades
- **Baseline Bootstrap**: Idempotent install of required Fedora packages
- **Global Opt-In**: All optional tools default to OFF; enable via profile, config, or CLI flags
- **Code-First Tool Logic**: Tool update behavior stays in code for clear review and predictable behavior
- **Profiles + Selectors**: Use `--profile`, `--only`, and `--skip` to avoid skip-flag sprawl as tools grow
- **Persistent Defaults**: Optional user config for default profile and `ENABLED_TOOLS` allowlist or `DISABLED_TOOLS` denylist
- **DNF Always-On**: `dnf` runs on every invocation unless explicitly `--skip dnf`
- **Idempotent**: Safe to run repeatedly; no-op when already current
- **Comprehensive Error Handling**: Detailed exit codes, lockfile-based concurrency control, and remediation hints
- **Dry-Run Mode**: Preview commands before execution
- **Strict Mode**: Fail immediately on any optional step failure (CI-friendly)
- **Detailed Logging**: Timestamped logs with step-by-step progress tracking

## AI-First Design

This project is designed to be modified safely by AI agents. [`AGENTS.md`](AGENTS.md) gives an agent everything it needs to make correct changes without human supervision:

- **Invariants** — hard constraints that must never be violated (gate sequence, wrapper requirement, strict bash mode, etc.)
- **Checklists** — step-by-step task lists for the most common changes: add a tool, add a CLI flag, add a config key
- **Decision criteria** — rules for non-obvious choices (`step_skip` vs `step_fail_optional`, critical vs optional failure classification, profile membership)
- **Exit code reference** — all defined exit codes to prevent collisions when adding new ones
- **Verification commands** — exact lint and smoke checks to run before committing

An AI agent with access to this repo can reliably add a new tool update function, add a CLI flag, or modify the config system — and verify the result — without asking for clarification.

## Installation

### Option 1: Run directly

```shell
./wsl-fedora-guest-tools [options]
```

### Option 2: Symlink to PATH (recommended)

```shell
ln -sf "$(pwd)/wsl-fedora-guest-tools" "$HOME/.local/bin/wsl-fedora-guest-tools"
```

Using `$(pwd)` ensures an absolute path in the symlink. After this, `git pull` automatically updates the installed command - no reinstall needed.

### Option 3: Copy to PATH (standalone)

```shell
install -m 0755 ./wsl-fedora-guest-tools "$HOME/.local/bin/wsl-fedora-guest-tools"
```

Copied files don't auto-update. After each `git pull`, re-run the `install` command above.

## Updating

```shell
cd /path/to/wsl-fedora-guest-tools && git pull
```

Symlink users (Option 2) are done - the command picks up changes immediately. Copy users (Option 3) must also re-run the `install` command.

## Usage

### Basic usage

```shell
# Run all updates (default profile: all)
./wsl-fedora-guest-tools

# Preview what would run (no changes made)
./wsl-fedora-guest-tools --dry-run

# Start from profile "dev" (dnf, volta, uv.self, uv.tools, gh)
./wsl-fedora-guest-tools --profile dev

# Run only specific tools
./wsl-fedora-guest-tools --only uv.self,claude

# Start from a profile, then remove selected tools
./wsl-fedora-guest-tools --profile all --skip codex,claude

# Show supported tool IDs and profile membership
./wsl-fedora-guest-tools --list-tools

# Fail on any error (useful for CI/CD)
./wsl-fedora-guest-tools --strict

# Override Fedora guard (use with caution)
./wsl-fedora-guest-tools --force
```

## Command-Line Options

| Flag                    | Description                                                |
|-------------------------|------------------------------------------------------------|
| `--dry-run`             | Print commands that would execute without running them     |
| `--force`               | Skip Fedora OS guard (still logs detected OS info)         |
| `--strict`              | Treat optional tool failures as fatal                      |
| `--profile <name>`      | Base selection profile: `all`, `core`, `dev`, or `ai`      |
| `--only <tool_ids_csv>` | Replace the current selection with exactly these tool IDs  |
| `--skip <tool_ids_csv>` | Remove these tool IDs from the current selection           |
| `--list-tools`          | Print supported tool IDs and profile membership, then exit |
| `--help, -h`            | Display usage information                                  |

## Tool IDs and Profiles

### Tool IDs

| Tool ID    | Description                                | Profiles                   |
|------------|--------------------------------------------|----------------------------|
| `dnf`      | System update + baseline bootstrap via DNF | `all`, `core`, `dev`, `ai` |
| `volta`    | Node.js update via Volta                   | `all`, `dev`               |
| `uv.self`  | uv self-update (`uv self update`)          | `all`, `dev`               |
| `uv.tools` | uv tool upgrades (`uv tool upgrade --all`) | `all`, `dev`               |
| `gh`       | GitHub CLI install/upgrade via DNF         | `all`, `dev`               |
| `claude`   | Claude Code CLI update                     | `all`, `ai`                |
| `codex`    | Codex CLI update via Volta                 | `all`, `ai`                |

### Profile definitions

| Profile | Tools                                        |
|---------|----------------------------------------------|
| `all`   | `dnf,volta,uv.self,uv.tools,gh,claude,codex` |
| `core`  | `dnf`                                        |
| `dev`   | `dnf,volta,uv.self,uv.tools,gh`              |
| `ai`    | `dnf,claude,codex`                           |

## Selection Precedence

Tool selection is resolved in this order:

1. Start with profile from CLI `--profile`; else config `DEFAULT_PROFILE`; else `all`
2. Apply config: `ENABLED_TOOLS` (allowlist: clear and enable only listed tools) **or** `DISABLED_TOOLS` (denylist: remove listed tools). These keys are mutually exclusive; setting both is a fatal error (exit 2).
3. If `--only` is provided, replace selection with exactly `--only`
4. Apply CLI `--skip`
5. Enforce DNF always-on: `dnf` is re-added unless `--skip dnf` was explicitly passed
6. `--only` + `--skip` is valid; final set is `only - skip` (plus `dnf` unless `--skip dnf`)

Notes:

- All optional tools default to OFF; a profile, `ENABLED_TOOLS`, `--profile`, or `--only` is required to enable them
- `dnf` always runs unless explicitly `--skip dnf` (infrastructure tool)
- Unknown tool IDs in CLI args are fatal (`exit 2`)
- Unknown tool IDs in config are ignored with a warning
- Invalid config profile is ignored with a warning and defaults to `all` unless CLI profile is provided

## Default Config File

Optional user config path:

`$XDG_CONFIG_HOME/wsl-fedora-guest-tools/config`

If `XDG_CONFIG_HOME` is not set, the fallback path is:

`$HOME/.config/wsl-fedora-guest-tools/config`

### Interactive First-Run Setup

If no config file exists and no CLI tool-selection flags (`--profile`, `--only`) are provided, the script prompts you interactively to choose a profile and writes a config file. This runs once (on first use) and only in a terminal session.

In non-interactive environments (CI, pipes), the script exits with an error and instructions to create the config file or pass CLI flags.

### Supported keys

- `DEFAULT_PROFILE=all|core|dev|ai` — base profile used when no `--profile` CLI flag is given
- `ENABLED_TOOLS=tool_id_csv` — allowlist: only the listed tool IDs are enabled (mutually exclusive with `DISABLED_TOOLS`)
- `DISABLED_TOOLS=tool_id_csv` — denylist: listed tools are removed from the profile selection (mutually exclusive with `ENABLED_TOOLS`)

Setting both `ENABLED_TOOLS` and `DISABLED_TOOLS` in the same config file is a fatal error (exit 2).

Unknown keys are ignored with a warning.

### Examples

```bash
# Opt-in allowlist: enable only specific tools
DEFAULT_PROFILE=all
ENABLED_TOOLS=volta,uv.self,uv.tools
```

With this config, default runs select `dnf,volta,uv.self,uv.tools` (`dnf` is always-on).

```bash
# Denylist: start from dev profile, disable gh
DEFAULT_PROFILE=dev
DISABLED_TOOLS=gh
```

With this config, default runs select `dnf,volta,uv.self,uv.tools`.

## Requirements

- **OS**: Fedora (use `--force` to bypass on non-Fedora systems)
- **Privileges**: Passwordless `sudo` required for DNF operations
- **Dependencies**:
  - `bash`
  - `flock` (from `util-linux`; used for lock-based concurrency control)
  - `dnf5`
- **Baseline packages installed by DNF bootstrap**:
  - Includes `bubblewrap`, which Codex requires for sandboxing
- **Optional tools** (for respective update steps):
  - `volta` (for `volta` and `codex` steps)
  - `uv` (for `uv.self` and `uv.tools` steps)
  - `gh` CLI (installed/managed by the `gh` step itself via DNF)
  - `claude` (for the `claude` step)
  - `codex` (for the `codex` step)

## Exit Codes

| Code | Meaning                                                |
|------|--------------------------------------------------------|
| `0`  | All steps completed successfully                       |
| `2`  | Invalid command-line arguments                         |
| `3`  | OS guard validation failed (not Fedora)                |
| `4`  | Passwordless sudo not available                        |
| `5`  | Another instance is already running (lock file exists) |
| `6`  | Missing required command                               |
| `10` | One or more optional steps failed (not in strict mode) |

## Update Steps

The script runs these steps in order:

1. **Lock**: Acquire lock file to prevent concurrent runs
2. **OS Guard**: Validate Fedora base distro (skippable with `--force`)
3. **Sudo Check**: Verify passwordless sudo is available
4. **System Update**: DNF package upgrade (always-on unless `--skip dnf`)
5. **Baseline DNF Bootstrap**: Install missing baseline packages (always-on unless `--skip dnf`)
6. **GitHub CLI Update**: Install or upgrade `gh` via DNF with gh-cli repo setup (when `gh` is selected)
7. **Volta Node Update**: Optional Node.js update via Volta (when `volta` is selected)
8. **uv Self-Update**: Optional uv self-update (when `uv.self` is selected)
9. **uv Tool Upgrade**: Optional uv tool upgrades (when `uv.tools` is selected)
10. **Claude Update**: Optional Claude Code CLI update (when `claude` is selected)
11. **Codex Update**: Optional Codex update via Volta (when `codex` is selected)

## Behavior Notes

### Idempotent design

- Safe to run multiple times
- Detects when tools are already up-to-date
- Does not reinstall unchanged versions
- Baseline DNF bootstrap installs only missing packages/repo configuration
- Optional tool failures do not stop execution unless `--strict` is enabled

### Error recovery

- Detailed error messages with remediation hints
- Captures command output for diagnosis
- Continues after optional tool failures in normal mode
- Prints a summary of all steps at completion

### uv self-update handling

- Detects when uv self-updates are disabled (`uv.self` step)
- Provides guidance to upgrade uv via its original install method
- `uv.tools` step runs independently regardless of `uv.self` outcome

### Claude update detection

- Treats updater "up to date" output as success
- Falls back to version comparison checks
- Provides hints for common installation paths/workflows

### Codex update handling

- Requires both `volta` and `codex` to be present
- Skips update if either is missing
- Uses `volta install @openai/codex@latest`
- Compares before/after versions when available

### DNF always-on

The `dnf` tool is infrastructure and runs by default on every invocation. It can be disabled only by explicitly passing `--skip dnf`. Profile selection and `ENABLED_TOOLS` do not suppress `dnf`.

### Global opt-in model

All optional tools default to OFF. To enable tools:

- Let the interactive first-run setup write a config file
- Create a config file manually with `DEFAULT_PROFILE` and/or `ENABLED_TOOLS`
- Pass `--profile` or `--only` on the command line

This ensures that users who configured the tool before new tools were added are never silently opted into tools they didn't request.

### ENABLED_TOOLS vs DISABLED_TOOLS

`ENABLED_TOOLS` is an allowlist: only the listed tool IDs run. `DISABLED_TOOLS` is a denylist: listed tools are removed from the base profile. These keys are mutually exclusive; using both is a fatal error (exit 2).

### GitHub CLI update

The `gh` tool manages the `gh-cli` DNF repository and installs or upgrades the `gh` package via `dnf5`. It is independent of the baseline bootstrap step. If `gh` is not selected, no DNF repo changes are made for gh-cli.

### uv operation separation

uv self-update (`uv.self`) and uv tool upgrades (`uv.tools`) are independent steps with separate tool IDs. This allows fine-grained control: for example, `--only uv.tools` runs only the tool upgrades without attempting the self-update.

## Contributing New Tools

This project intentionally keeps tool behavior in code. For any new tool PR:

- Add a canonical tool ID plus description/profile metadata in the script registry
- Implement idempotent update behavior (pre-check or post-check no-op safety)
- Ensure selector compatibility (`--profile`, `--only`, `--skip`)
- Keep dry-run output parity for the new step
- Classify failures correctly (`critical` vs `optional`) and include remediation hints
- Update README sections:
    - Tool IDs and Profiles
    - Examples (if applicable)
    - Any behavior notes specific to the tool

## Continuous Integration

GitHub Actions runs static quality checks through the npm-locked `prek` hook
runner, then runs smoke tests on a matrix of supported Fedora versions
(currently Fedora 42 and 43).

**Triggers:**

- Every PR
- Every push to `main`
- Weekly scheduled run (Monday 07:13 UTC)
- Manual runs via `workflow_dispatch`

**Checks:**

- `bash -n` syntax validation through `prek`
- `shellcheck` linting through `prek`
- `shfmt` format checks through `prek`
- GitHub Actions workflow lint/security checks through `actionlint` and
  `zizmor`
- `--help`, `--list-tools`, and dry-run smoke scenarios

**Practices:**

- All third-party actions are pinned to SHA digests for supply-chain security
- Static quality tooling is installed from `package-lock.json` and runs the
  same `.pre-commit-config.yaml` hooks locally and in CI
- Dependabot tracks GitHub Actions, npm development tooling, and pre-commit
  hook updates with grouped PRs and cooldowns

**Automated failure alerts:**

For scheduled runs, a `notify-scheduled-failure` job creates (or updates) a
GitHub issue titled `Scheduled CI failure detected` (labeled `ci-scheduled`)
when CI fails, then automatically closes it on the next successful scheduled
run.

## Troubleshooting

### "Passwordless sudo is required"

> **Note:** Fedora WSL images often configure this by default.

Configure passwordless sudo via `sudo visudo`:

```bash
your_username ALL=(ALL) NOPASSWD: ALL
```

### "Another instance is already running"

If a previous run crashed, verify no active process is holding the lock and remove stale lock file if needed:

```shell
rm /tmp/wsl-fedora-guest-tools.lock
```

The lock is usually located at `$XDG_RUNTIME_DIR/wsl-fedora-guest-tools.lock` or `/tmp/wsl-fedora-guest-tools.lock`.

### Optional tool update failures

- In normal mode, optional failures do not prevent remaining steps from running
- Normal mode exits `10` if one or more optional steps fail
- Use `--strict` to fail immediately on first optional failure
- Check the final summary to identify failing steps and apply remediation hints
