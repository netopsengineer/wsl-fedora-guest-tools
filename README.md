# WSL Fedora Guest Tools

A robust bootstrapper and idempotent update utility for Fedora WSL environments. It orchestrates critical system installs and updates via DNF (with `dnf5` preference) alongside optional updates for developer tools and AI CLIs: Volta/Node.js, `uv`, Claude Code, and Codex.

## Why

Developer tooling and AI CLIs change frequently. Keeping everything current often resolves issues quickly and unlocks new features. On macOS, `brew update && brew upgrade` makes this easy. This project provides a similarly reliable workflow for Fedora on WSL.

## Features

- **System Updates**: Safe DNF-based system package upgrades (`dnf5` preferred, falls back to `dnf`)
- **Baseline Bootstrap**: Idempotent install of required Fedora packages and GitHub CLI repository/package
- **Backend-Aware DNF Repo Setup**: Uses `dnf5` and `dnf` compatible commands for GitHub CLI repo enablement
- **Code-First Tool Logic**: Tool update behavior stays in code for clear review and predictable behavior
- **Profiles + Selectors**: Use `--profile`, `--only`, and `--skip` to avoid skip-flag sprawl as tools grow
- **Persistent Defaults**: Optional user config for default profile and disabled tools
- **Idempotent**: Safe to run repeatedly; no-op when already current
- **Comprehensive Error Handling**: Detailed exit codes, lockfile-based concurrency control, and remediation hints
- **Dry-Run Mode**: Preview commands before execution
- **Strict Mode**: Fail immediately on any optional step failure (CI-friendly)
- **Detailed Logging**: Timestamped logs with step-by-step progress tracking

## Installation

### Option 1: Run from within the project

```shell
./wsl-fedora-guest-tools.sh [options]
```

### Option 2: Install to your PATH

```shell
install -m 0755 ./wsl-fedora-guest-tools.sh "$HOME/.local/bin/wsl-fedora-guest-tools"
wsl-fedora-guest-tools [options]
```

## Usage

### Basic usage

```shell
# Run all updates (default profile: all)
./wsl-fedora-guest-tools.sh

# Preview what would run (no changes made)
./wsl-fedora-guest-tools.sh --dry-run

# Start from profile "dev" (dnf, volta, uv)
./wsl-fedora-guest-tools.sh --profile dev

# Run only specific tools
./wsl-fedora-guest-tools.sh --only uv,claude

# Start from a profile, then remove selected tools
./wsl-fedora-guest-tools.sh --profile all --skip codex,claude

# Show supported tool IDs and profile membership
./wsl-fedora-guest-tools.sh --list-tools

# Fail on any error (useful for CI/CD)
./wsl-fedora-guest-tools.sh --strict

# Override Fedora guard (use with caution)
./wsl-fedora-guest-tools.sh --force
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

| Tool ID  | Description                                | Profiles                   |
|----------|--------------------------------------------|----------------------------|
| `dnf`    | System update + baseline bootstrap via DNF | `all`, `core`, `dev`, `ai` |
| `volta`  | Node.js update via Volta                   | `all`, `dev`               |
| `uv`     | uv self-update and uv tool upgrades        | `all`, `dev`               |
| `claude` | Claude Code CLI update                     | `all`, `ai`                |
| `codex`  | Codex CLI update via Volta                 | `all`, `ai`                |

### Profile definitions

| Profile | Tools                       |
|---------|-----------------------------|
| `all`   | `dnf,volta,uv,claude,codex` |
| `core`  | `dnf`                       |
| `dev`   | `dnf,volta,uv`              |
| `ai`    | `dnf,claude,codex`          |

## Selection Precedence

Tool selection is resolved in this order:

1. Start with profile from CLI `--profile`; else config `DEFAULT_PROFILE`; else `all`
2. Apply config `DISABLED_TOOLS`
3. If `--only` is provided, replace selection with exactly `--only`
4. Apply CLI `--skip`
5. `--only` + `--skip` is valid; final set is `only - skip`

Notes:

- Unknown tool IDs in CLI args are fatal (`exit 2`)
- Unknown tool IDs in config are ignored with a warning
- Invalid config profile is ignored with a warning and defaults to `all` unless CLI profile is provided

## Default Config File

Optional user config path:

`$XDG_CONFIG_HOME/wsl-fedora-guest-tools/config`

If `XDG_CONFIG_HOME` is not set, the fallback path is:

`$HOME/.config/wsl-fedora-guest-tools/config`

Supported keys:

- `DEFAULT_PROFILE=all|core|dev|ai`
- `DISABLED_TOOLS=tool_id_csv`

Unknown keys are ignored with a warning.

Example:

```bash
# ~/.config/wsl-fedora-guest-tools/config
DEFAULT_PROFILE=dev
DISABLED_TOOLS=uv
```

With this config, default runs select `dnf,volta` unless overridden by CLI flags.

## Requirements

- **OS**: Fedora (use `--force` to bypass on non-Fedora systems)
- **Privileges**: Passwordless `sudo` required for DNF operations
- **Dependencies**:
  - `bash`
  - `flock` (from `util-linux`; used for lock-based concurrency control)
  - `dnf` or `dnf5`
- **Optional tools** (for respective update steps):
  - `volta` (for Node.js management and Codex)
  - `uv`
  - `claude`
  - `codex`

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
4. **System Update**: DNF package upgrade (runs when `dnf` is selected)
5. **Baseline DNF Bootstrap**: Install missing baseline packages and GitHub CLI repo/package setup (runs when `dnf` is selected)
6. **Volta Node Update**: Optional Node.js update via Volta (runs when `volta` is selected)
7. **uv Update**: Optional uv self-update and tool upgrades (runs when `uv` is selected)
8. **Claude Update**: Optional Claude Code CLI update (runs when `claude` is selected)
9. **Codex Update**: Optional Codex update via Volta (runs when `codex` is selected)

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

- Detects when uv self-updates are disabled
- Provides guidance to upgrade uv via its original install method
- Continues with `uv tool upgrade --all` when possible

### Claude update detection

- Treats updater "up to date" output as success
- Falls back to version comparison checks
- Provides hints for common installation paths/workflows

### Codex update handling

- Requires both `volta` and `codex` to be present
- Skips update if either is missing
- Uses `volta install @openai/codex@latest`
- Compares before/after versions when available

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

GitHub Actions runs static quality checks and smoke tests for:

- every PR
- every push to `main`
- a weekly scheduled run (Monday 07:13 UTC)
- manual runs via `workflow_dispatch`

- `bash -n` syntax validation
- `shellcheck` linting
- `shfmt -d` format checks
- `--help`, `--list-tools`, and dry-run smoke scenarios

For scheduled runs, GitHub Actions also creates (or updates) an issue titled
`Scheduled CI failure detected` when CI fails, then automatically closes it on
the next successful scheduled run.

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
