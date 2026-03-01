#!/usr/bin/env bash
set -Eeuo pipefail

# WSL Fedora guest tools updater: DNF OS/package bootstrap (critical) + optional developer tool updates.
# ShellCheck-friendly, idempotent, and guarded with lock + strong error reporting.

readonly LOCK_BASENAME="wsl-fedora-guest-tools.lock"
readonly EXIT_USAGE=2
readonly EXIT_OS_GUARD=3
readonly EXIT_SUDO=4
readonly EXIT_LOCK=5
readonly EXIT_MISSING_CMD=6
readonly EXIT_OPTIONAL_FAILED=10
readonly GH_CLI_REPO_ID="gh-cli"
readonly GH_CLI_REPOFILE_URL="https://cli.github.com/packages/rpm/gh-cli.repo"
readonly GH_CLI_REPO_FILE="/etc/yum.repos.d/${GH_CLI_REPO_ID}.repo"
readonly DEFAULT_PROFILE_NAME="all"
readonly PROFILE_ALL_TOOLS="dnf,volta,uv,claude,codex"
readonly PROFILE_CORE_TOOLS="dnf"
readonly PROFILE_DEV_TOOLS="dnf,volta,uv"
readonly PROFILE_AI_TOOLS="dnf,claude,codex"
readonly -a TOOL_IDS=("dnf" "volta" "uv" "claude" "codex")
readonly DNF5_PLUGIN_PACKAGE="dnf5-plugins"
readonly DNF_PLUGIN_PACKAGE="dnf-plugins-core"
readonly -a BASELINE_PACKAGES_COMMON=(
	"libgcc"
	"libstdc++"
	"libatomic"
	"ncurses"
	"libevent"
	"gawk"
	"git"
	"jq"
	"ripgrep"
	"tmux"
	"ShellCheck"
	"shfmt"
	"util-linux"
)

DRY_RUN=0
FORCE=0
STRICT=0
LIST_TOOLS=0
CLI_PROFILE=""
CLI_PROFILE_SET=0
CLI_ONLY=""
CLI_ONLY_SET=0
CLI_SKIP=""
CLI_SKIP_SET=0
CONFIG_DEFAULT_PROFILE=""
CONFIG_DISABLED_TOOLS=""
ACTIVE_PROFILE="${DEFAULT_PROFILE_NAME}"
SKIP_SUMMARY=0
SKIP_DNF=0
SKIP_UV=0
SKIP_CLAUDE=0
SKIP_VOLTA=0
SKIP_CODEX=0

CURRENT_STEP=""
OPTIONAL_FAILURES=0
DNF_BACKEND=""

# Last captured output from run_cmd_optional_capture (stdout+stderr).
LAST_CMD_OUT=""

declare -A STEP_STATUS=()
declare -A STEP_DETAIL=()
declare -A TOOL_DESCRIPTIONS=(
	["dnf"]="System update + baseline bootstrap via DNF"
	["volta"]="Node.js update via Volta"
	["uv"]="uv self-update and tool upgrades"
	["claude"]="Claude Code CLI update"
	["codex"]="Codex CLI update via Volta"
)
declare -A TOOL_PROFILES=(
	["dnf"]="all,core,dev,ai"
	["volta"]="all,dev"
	["uv"]="all,dev"
	["claude"]="all,ai"
	["codex"]="all,ai"
)
declare -A TOOL_SELECTED=(
	["dnf"]=1
	["volta"]=1
	["uv"]=1
	["claude"]=1
	["codex"]=1
)
declare -a STEP_ORDER=()

ts() {
	date '+%Y-%m-%dT%H:%M:%S%z'
}

log() {
	printf '%s [INFO] %s\n' "$(ts)" "$*"
}

warn() {
	printf '%s [WARN] %s\n' "$(ts)" "$*" >&2
}

error() {
	printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2
}

die() {
	local code="${1:-1}"
	shift || true
	error "$*"
	exit "${code}"
}

have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

fmt_cmd() {
	local -a q=()
	local arg
	for arg in "$@"; do
		q+=("$(printf '%q' "${arg}")")
	done
	printf '%s' "${q[*]}"
}

trim_ws() {
	local text="$1"
	text="${text#"${text%%[![:space:]]*}"}"
	text="${text%"${text##*[![:space:]]}"}"
	printf '%s' "${text}"
}

to_lower() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_valid_profile() {
	case "$1" in
	all | core | dev | ai) return 0 ;;
	*) return 1 ;;
	esac
}

profile_tools_csv() {
	case "$1" in
	all) printf '%s' "${PROFILE_ALL_TOOLS}" ;;
	core) printf '%s' "${PROFILE_CORE_TOOLS}" ;;
	dev) printf '%s' "${PROFILE_DEV_TOOLS}" ;;
	ai) printf '%s' "${PROFILE_AI_TOOLS}" ;;
	*) return 1 ;;
	esac
}

is_valid_tool_id() {
	case "$1" in
	dnf | volta | uv | claude | codex) return 0 ;;
	*) return 1 ;;
	esac
}

parse_csv_to_array() {
	local csv="$1"
	local -n out_ref="$2"
	local -a raw=()
	local item

	out_ref=()
	csv="$(trim_ws "${csv}")"
	if [[ -z "${csv}" ]]; then
		return 0
	fi

	IFS=',' read -r -a raw <<<"${csv}"
	for item in "${raw[@]}"; do
		item="$(to_lower "$(trim_ws "${item}")")"
		if [[ -n "${item}" ]]; then
			out_ref+=("${item}")
		fi
	done
}

filter_tool_ids() {
	local context="$1"
	local csv="$2"
	local strict="$3"
	# shellcheck disable=SC2178
	local -n out_ref="$4"
	local -a parsed=()
	local id

	out_ref=()
	parse_csv_to_array "${csv}" parsed

	for id in "${parsed[@]}"; do
		if is_valid_tool_id "${id}"; then
			out_ref+=("${id}")
			continue
		fi

		if ((strict == 1)); then
			usage
			die "${EXIT_USAGE}" "Unknown tool id in ${context}: ${id}. Use --list-tools to view valid IDs."
		fi

		warn "Ignoring unknown tool id in ${context}: ${id}"
	done
}

clear_tool_selection() {
	local id
	for id in "${TOOL_IDS[@]}"; do
		TOOL_SELECTED["${id}"]=0
	done
}

add_tool_ids_to_selection() {
	local id
	for id in "$@"; do
		TOOL_SELECTED["${id}"]=1
	done
}

remove_tool_ids_from_selection() {
	local id
	for id in "$@"; do
		TOOL_SELECTED["${id}"]=0
	done
}

set_selection_from_profile() {
	local profile="$1"
	local csv
	local -a ids=()

	if ! csv="$(profile_tools_csv "${profile}")"; then
		return 1
	fi

	parse_csv_to_array "${csv}" ids
	clear_tool_selection
	add_tool_ids_to_selection "${ids[@]}"
}

tool_is_selected() {
	local id="$1"
	[[ "${TOOL_SELECTED["${id}"]:-0}" == "1" ]]
}

selected_tools_csv() {
	local id
	local -a selected=()
	for id in "${TOOL_IDS[@]}"; do
		if tool_is_selected "${id}"; then
			selected+=("${id}")
		fi
	done

	if ((${#selected[@]} == 0)); then
		printf 'none'
		return 0
	fi

	local IFS=','
	printf '%s' "${selected[*]}"
}

config_file_path() {
	printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/wsl-fedora-guest-tools/config"
}

load_config() {
	local config_file line key value
	local lineno=0
	config_file="$(config_file_path)"

	if [[ ! -f "${config_file}" ]]; then
		return 0
	fi

	if [[ ! -r "${config_file}" ]]; then
		warn "Config file exists but is not readable: ${config_file}"
		return 0
	fi

	while IFS= read -r line || [[ -n "${line}" ]]; do
		lineno=$((lineno + 1))

		if [[ "${line}" =~ ^[[:space:]]*$ ]] || [[ "${line}" =~ ^[[:space:]]*# ]]; then
			continue
		fi

		if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
			key="${BASH_REMATCH[1]}"
			value="$(trim_ws "${BASH_REMATCH[2]}")"

			if [[ "${value}" == \"*\" && "${value}" == *\" && ${#value} -ge 2 ]]; then
				value="${value:1:${#value}-2}"
			elif [[ "${value}" == \'*\' && "${value}" == *\' && ${#value} -ge 2 ]]; then
				value="${value:1:${#value}-2}"
			fi

			case "${key}" in
			DEFAULT_PROFILE) CONFIG_DEFAULT_PROFILE="${value}" ;;
			DISABLED_TOOLS) CONFIG_DISABLED_TOOLS="${value}" ;;
			*) warn "Ignoring unknown config key ${key} in ${config_file}:${lineno}" ;;
			esac
			continue
		fi

		warn "Ignoring malformed config line ${config_file}:${lineno}"
	done <"${config_file}"
}

apply_selected_tools_to_skip_flags() {
	SKIP_DNF=1
	SKIP_VOLTA=1
	SKIP_UV=1
	SKIP_CLAUDE=1
	SKIP_CODEX=1

	if tool_is_selected "dnf"; then
		SKIP_DNF=0
	fi
	if tool_is_selected "volta"; then
		SKIP_VOLTA=0
	fi
	if tool_is_selected "uv"; then
		SKIP_UV=0
	fi
	if tool_is_selected "claude"; then
		SKIP_CLAUDE=0
	fi
	if tool_is_selected "codex"; then
		SKIP_CODEX=0
	fi
}

resolve_tool_selection() {
	local normalized_profile
	local -a config_disabled_ids=()
	local -a only_ids=()
	local -a skip_ids=()

	ACTIVE_PROFILE="${DEFAULT_PROFILE_NAME}"

	if ((CLI_PROFILE_SET == 1)); then
		normalized_profile="$(to_lower "$(trim_ws "${CLI_PROFILE}")")"
		if ! is_valid_profile "${normalized_profile}"; then
			usage
			die "${EXIT_USAGE}" "Invalid profile: ${CLI_PROFILE}. Valid profiles: all, core, dev, ai."
		fi
		ACTIVE_PROFILE="${normalized_profile}"
	elif [[ -n "${CONFIG_DEFAULT_PROFILE}" ]]; then
		normalized_profile="$(to_lower "$(trim_ws "${CONFIG_DEFAULT_PROFILE}")")"
		if is_valid_profile "${normalized_profile}"; then
			ACTIVE_PROFILE="${normalized_profile}"
		else
			warn "Ignoring invalid DEFAULT_PROFILE in $(config_file_path): ${CONFIG_DEFAULT_PROFILE}"
		fi
	fi

	set_selection_from_profile "${ACTIVE_PROFILE}"

	filter_tool_ids "DISABLED_TOOLS in $(config_file_path)" "${CONFIG_DISABLED_TOOLS}" 0 config_disabled_ids
	remove_tool_ids_from_selection "${config_disabled_ids[@]}"

	if ((CLI_ONLY_SET == 1)); then
		filter_tool_ids "--only" "${CLI_ONLY}" 1 only_ids
		clear_tool_selection
		add_tool_ids_to_selection "${only_ids[@]}"
	fi

	if ((CLI_SKIP_SET == 1)); then
		filter_tool_ids "--skip" "${CLI_SKIP}" 1 skip_ids
		remove_tool_ids_from_selection "${skip_ids[@]}"
	fi

	apply_selected_tools_to_skip_flags

	log "Tool profile selected: ${ACTIVE_PROFILE}"
	log "Final tool selection: $(selected_tools_csv)"
}

print_tool_catalog() {
	local id
	printf 'Supported tool IDs:\n'
	for id in "${TOOL_IDS[@]}"; do
		printf '  %-7s %s (profiles: %s)\n' "${id}" "${TOOL_DESCRIPTIONS["${id}"]}" "${TOOL_PROFILES["${id}"]}"
	done

	printf '\n'
	printf 'Profiles:\n'
	printf '  all  : %s\n' "${PROFILE_ALL_TOOLS}"
	printf '  core : %s\n' "${PROFILE_CORE_TOOLS}"
	printf '  dev  : %s\n' "${PROFILE_DEV_TOOLS}"
	printf '  ai   : %s\n' "${PROFILE_AI_TOOLS}"
}

option_value_or_die() {
	local flag="$1"
	local value="${2:-}"

	if [[ -z "${value}" ]] || [[ "${value}" == --* ]]; then
		usage
		die "${EXIT_USAGE}" "Missing value for ${flag}"
	fi

	printf '%s' "${value}"
}

step_begin() {
	local name="$1"
	CURRENT_STEP="${name}"
	STEP_ORDER+=("${name}")
	STEP_STATUS["${name}"]="RUNNING"
	STEP_DETAIL["${name}"]=""
	log "==> ${name}"
}

step_set() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	STEP_STATUS["${name}"]="${status}"
	STEP_DETAIL["${name}"]="${detail}"
}

step_ok() {
	local name="${1:-$CURRENT_STEP}"
	local detail="${2:-}"
	step_set "${name}" "OK" "${detail}"
}

step_skip() {
	local name="${1:-$CURRENT_STEP}"
	local detail="${2:-}"
	step_set "${name}" "SKIPPED" "${detail}"
}

record_optional_failure() {
	OPTIONAL_FAILURES=$((OPTIONAL_FAILURES + 1))
}

step_fail_optional() {
	local name="${1:-$CURRENT_STEP}"
	local detail="${2:-}"
	step_set "${name}" "FAILED" "${detail}"
	record_optional_failure

	if ((STRICT == 1)); then
		die 1 "Strict mode: aborting due to failure in step: ${name}. ${detail}"
	fi
}

# shellcheck disable=SC2329
on_err() {
	local rc="$1"
	local line="$2"
	local cmd="$3"

	error "Unhandled failure: cmd=$(printf '%q' "${cmd}") exit=${rc} line=${line}"

	if [[ -n "${CURRENT_STEP:-}" ]] && [[ "${STEP_STATUS["${CURRENT_STEP}"]:-}" == "RUNNING" ]]; then
		step_set "${CURRENT_STEP}" "FAILED" "Command failed (exit ${rc}) at line ${line}"
	fi
}

# shellcheck disable=SC2329
print_summary() {
	local name status detail
	printf '\n'
	log "Summary"
	for name in "${STEP_ORDER[@]}"; do
		status="${STEP_STATUS["${name}"]:-INCOMPLETE}"
		detail="${STEP_DETAIL["${name}"]:-}"
		if [[ -n "${detail}" ]]; then
			printf '%s [INFO] - %-28s : %-9s (%s)\n' "$(ts)" "${name}" "${status}" "${detail}"
		else
			printf '%s [INFO] - %-28s : %-9s\n' "$(ts)" "${name}" "${status}"
		fi
	done

	if ((OPTIONAL_FAILURES > 0)); then
		warn "Optional step failures: ${OPTIONAL_FAILURES} (final exit will be non-zero unless a critical failure already occurred)."
	fi
}

# shellcheck disable=SC2329
on_exit() {
	local rc="$1"

	trap - EXIT
	if ((SKIP_SUMMARY == 1)); then
		exit "${rc}"
	fi
	print_summary

	if ((rc == 0 && OPTIONAL_FAILURES > 0)); then
		exit "${EXIT_OPTIONAL_FAILED}"
	fi

	exit "${rc}"
}

usage() {
	cat <<'EOF'
WSL Fedora guest tools updater: critical DNF system upgrade/bootstrap (prefers dnf5), plus optional updates for uv, Volta/Node, Claude Code, and Codex.

Usage:
  wsl-fedora-guest-tools.sh [--dry-run] [--force] [--strict] [--profile <name>] [--only <tool_ids_csv>] [--skip <tool_ids_csv>] [--list-tools]

Flags:
  --dry-run         Print what would run; do not execute update commands.
  --force           Skip Fedora guard (still logs detected OS info).
  --strict          Any failure is fatal (including optional tool steps).
  --profile <name>  Tool profile to start from: all, core, dev, ai.
  --only <csv>      Replace profile selection with exactly these tool IDs.
  --skip <csv>      Remove these tool IDs from the current selection.
  --list-tools      Print supported tool IDs and profile membership, then exit.
  --help            Show this help.
EOF
}

parse_args() {
	while (($# > 0)); do
		case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--force) FORCE=1 ;;
		--strict) STRICT=1 ;;
		--list-tools) LIST_TOOLS=1 ;;
		--profile)
			CLI_PROFILE="$(option_value_or_die "--profile" "${2:-}")"
			CLI_PROFILE_SET=1
			shift
			;;
		--profile=*)
			CLI_PROFILE="${1#*=}"
			CLI_PROFILE_SET=1
			;;
		--only)
			CLI_ONLY="$(option_value_or_die "--only" "${2:-}")"
			CLI_ONLY_SET=1
			shift
			;;
		--only=*)
			CLI_ONLY="${1#*=}"
			CLI_ONLY_SET=1
			;;
		--skip)
			CLI_SKIP="$(option_value_or_die "--skip" "${2:-}")"
			CLI_SKIP_SET=1
			shift
			;;
		--skip=*)
			CLI_SKIP="${1#*=}"
			CLI_SKIP_SET=1
			;;
		--help | -h)
			SKIP_SUMMARY=1
			usage
			exit 0
			;;
		*)
			usage
			die "${EXIT_USAGE}" "Unknown argument: $1"
			;;
		esac
		shift
	done
}

require_cmd_or_die() {
	local cmd="$1"
	local hint="$2"
	if ! have_cmd "${cmd}"; then
		die "${EXIT_MISSING_CMD}" "Missing required command: ${cmd}. ${hint}"
	fi
}

set_dnf_backend_or_die() {
	if [[ -n "${DNF_BACKEND}" ]]; then
		return 0
	fi

	if have_cmd "dnf5"; then
		DNF_BACKEND="dnf5"
	elif have_cmd "dnf"; then
		DNF_BACKEND="dnf"
	else
		if [[ -n "${CURRENT_STEP:-}" ]] && [[ "${STEP_STATUS["${CURRENT_STEP}"]:-}" == "RUNNING" ]]; then
			step_set "${CURRENT_STEP}" "FAILED" "Neither dnf5 nor dnf found"
		fi
		die "${EXIT_MISSING_CMD}" "Neither dnf5 nor dnf is available. Install DNF, then re-run."
	fi
}

extract_first_semver() {
	local text="$1"
	if [[ "${text}" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

latest_node_version_from_volta() {
	local out
	if ! out="$(volta fetch node@latest --verbose 2>&1)"; then
		return 1
	fi
	if [[ "${out}" =~ latest[[:space:]]node[[:space:]]version[[:space:]]\(([0-9]+\.[0-9]+\.[0-9]+)\) ]]; then
		printf 'v%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

latest_codex_version_from_npm() {
	local out semver

	if ! have_cmd "npm"; then
		return 1
	fi

	if ! out="$(npm view @openai/codex version --json --loglevel=error 2>/dev/null)"; then
		return 1
	fi

	if ! semver="$(extract_first_semver "${out}")"; then
		return 1
	fi

	printf '%s' "${semver}"
	return 0
}

acquire_lock() {
	step_begin "Lock"

	require_cmd_or_die "flock" "Install util-linux (for example: sudo dnf install -y util-linux)."

	local lock_dir lock_file
	lock_dir="${XDG_RUNTIME_DIR:-/tmp}"
	lock_file="${lock_dir%/}/${LOCK_BASENAME}"

	exec 9>"${lock_file}"
	if ! flock -n 9; then
		step_set "${CURRENT_STEP}" "FAILED" "Another run is in progress (lock: ${lock_file})"
		die "${EXIT_LOCK}" "Another instance is already running (lock: ${lock_file})."
	fi

	step_ok "${CURRENT_STEP}" "Acquired ${lock_file}"
}

validate_fedora() {
	step_begin "OS guard"

	if [[ ! -r /etc/os-release ]]; then
		step_set "${CURRENT_STEP}" "FAILED" "/etc/os-release not readable"
		die "${EXIT_OS_GUARD}" "Cannot read /etc/os-release to validate OS."
	fi

	# shellcheck disable=SC1091
	source /etc/os-release

	local id version
	id="${ID:-}"
	version="${VERSION_ID:-}"

	if ((FORCE == 1)); then
		warn "Force enabled: skipping Fedora guard. Detected ID=${id:-unknown} VERSION_ID=${version:-unknown}."
		step_ok "${CURRENT_STEP}" "Forced (detected ID=${id:-?} VERSION_ID=${version:-?})"
		return 0
	fi

	if [[ "${id}" != "fedora" ]]; then
		step_set "${CURRENT_STEP}" "FAILED" "Detected ID=${id:-?} VERSION_ID=${version:-?}"
		die "${EXIT_OS_GUARD}" "This script targets Fedora only. Detected ID=${id:-?} VERSION_ID=${version:-?}. Use --force to override."
	fi

	step_ok "${CURRENT_STEP}" "Fedora (VERSION_ID=${version:-unknown})"
}

validate_passwordless_sudo() {
	step_begin "Sudo check"

	require_cmd_or_die "sudo" "Install sudo, and ensure passwordless sudo is configured for your user."

	if ! sudo -n true >/dev/null 2>&1; then
		step_set "${CURRENT_STEP}" "FAILED" "sudo -n true failed"
		die "${EXIT_SUDO}" "Passwordless sudo is required. Configure NOPASSWD in sudoers for this user, then re-run."
	fi

	step_ok "${CURRENT_STEP}" "sudo -n ok"
}

run_cmd_fatal() {
	local display
	display="$(fmt_cmd "$@")"
	if ((DRY_RUN == 1)); then
		log "DRY-RUN: ${display}"
		return 0
	fi
	log "RUN: ${display}"
	"$@"
}

run_cmd_optional_capture() {
	# Captures stdout+stderr to allow error-specific hints while keeping output visible.
	# Returns the command exit code, but does not trigger ERR trap due to conditional usage.
	local -a cmd=("$@")
	local display out rc

	LAST_CMD_OUT=""
	display="$(fmt_cmd "${cmd[@]}")"

	if ((DRY_RUN == 1)); then
		log "DRY-RUN: ${display}"
		LAST_CMD_OUT=""
		printf '' # keep consistent behavior
		return 0
	fi

	log "RUN: ${display}"
	out="$("${cmd[@]}" 2>&1)" || rc=$?
	rc="${rc:-0}"
	LAST_CMD_OUT="${out}"

	if [[ -n "${out}" ]]; then
		while IFS= read -r line; do
			log "OUT: ${line}"
		done <<<"${out}"
	fi

	return "${rc}"
}

dnf_system_update() {
	step_begin "System update"

	if ((SKIP_DNF == 1)); then
		step_skip "${CURRENT_STEP}" "Tool 'dnf' not selected"
		return 0
	fi

	set_dnf_backend_or_die
	local backend="${DNF_BACKEND}"
	log "DNF backend selected: ${backend}"
	step_set "${CURRENT_STEP}" "RUNNING" "backend=${backend}"
	run_cmd_fatal sudo "${backend}" --refresh upgrade -y

	step_ok "${CURRENT_STEP}" "backend=${backend}"
}

baseline_dnf_bootstrap() {
	step_begin "Baseline DNF bootstrap"

	if ((SKIP_DNF == 1)); then
		step_skip "${CURRENT_STEP}" "Tool 'dnf' not selected"
		return 0
	fi

	require_cmd_or_die "rpm" "Install rpm, then re-run."
	set_dnf_backend_or_die

	local backend pkg
	local -a required_packages=()
	local -a missing_packages=()
	local pkg_detail gh_detail repo_detail
	backend="${DNF_BACKEND}"
	pkg_detail="already-present"
	gh_detail="already-installed"
	repo_detail="not-needed"

	required_packages=("${BASELINE_PACKAGES_COMMON[@]}")
	if [[ "${backend}" == "dnf5" ]]; then
		required_packages+=("${DNF5_PLUGIN_PACKAGE}")
	else
		required_packages+=("${DNF_PLUGIN_PACKAGE}")
	fi

	for pkg in "${required_packages[@]}"; do
		if ! rpm -q --quiet "${pkg}"; then
			missing_packages+=("${pkg}")
		fi
	done

	step_set "${CURRENT_STEP}" "RUNNING" "backend=${backend}"

	if ((${#missing_packages[@]} > 0)); then
		run_cmd_fatal sudo "${backend}" install -y "${missing_packages[@]}"
		pkg_detail="installed:${#missing_packages[@]}"
	fi

	if ! rpm -q --quiet "gh"; then
		gh_detail="installed"
		if [[ -f "${GH_CLI_REPO_FILE}" ]]; then
			repo_detail="already-present"
		else
			if [[ "${backend}" == "dnf5" ]]; then
				run_cmd_fatal sudo "${backend}" config-manager addrepo --from-repofile="${GH_CLI_REPOFILE_URL}"
			else
				run_cmd_fatal sudo "${backend}" config-manager --add-repo "${GH_CLI_REPOFILE_URL}"
			fi
			repo_detail="added"
		fi
		if [[ "${backend}" == "dnf5" ]]; then
			run_cmd_fatal sudo "${backend}" install -y gh --repo "${GH_CLI_REPO_ID}"
		else
			run_cmd_fatal sudo "${backend}" install -y gh --enablerepo="${GH_CLI_REPO_ID}"
		fi
	fi

	step_ok "${CURRENT_STEP}" "backend=${backend}, pkgs=${pkg_detail}, gh=${gh_detail}, gh-repo=${repo_detail}"
}

volta_node_update() {
	step_begin "Volta Node update"

	if ((SKIP_VOLTA == 1)); then
		step_skip "${CURRENT_STEP}" "Tool 'volta' not selected"
		return 0
	fi

	if ! have_cmd "volta"; then
		warn "volta not found."
		warn "Remediation: verify with 'command -v volta' and 'volta --version'. Install Volta (https://volta.sh), then re-run."
		step_fail_optional "${CURRENT_STEP}" "volta missing"
		return 0
	fi

	local old_ver new_ver install_rc latest_ver
	old_ver=""
	new_ver=""
	install_rc=0
	latest_ver=""

	if ((DRY_RUN == 1)); then
		log "DRY-RUN: node --version (via volta)"
		log "DRY-RUN: volta install node@latest"
		log "DRY-RUN: node --version (via volta)"
		step_ok "${CURRENT_STEP}" "dry-run"
		return 0
	fi

	if have_cmd "node"; then
		old_ver="$(node --version 2>&1 | head -n 1)" || old_ver="(unable to read version)"
	else
		old_ver="(not installed)"
	fi
	log "Node version before update: ${old_ver}"

	if [[ "${old_ver}" != "(not installed)" ]] && latest_ver="$(latest_node_version_from_volta)"; then
		log "Latest Node version available via Volta: ${latest_ver}"
		if [[ "${old_ver}" == "${latest_ver}" ]]; then
			step_ok "${CURRENT_STEP}" "up-to-date (${old_ver})"
			return 0
		fi
	else
		log "Node latest-version pre-check unavailable; falling back to install check."
	fi

	if ! run_cmd_optional_capture volta install node@latest; then
		install_rc=$?
		warn "volta install node@latest failed (exit ${install_rc})."
		step_fail_optional "${CURRENT_STEP}" "volta install failed (exit ${install_rc})"
		return 0
	fi

	new_ver="$(node --version 2>&1 | head -n 1)" || new_ver="(unable to read version)"
	log "Node version after update: ${new_ver}"

	if [[ "${old_ver}" == "${new_ver}" ]]; then
		step_ok "${CURRENT_STEP}" "up-to-date (${new_ver})"
	else
		step_ok "${CURRENT_STEP}" "${old_ver} -> ${new_ver}"
	fi
}

uv_update() {
	step_begin "uv update"

	if ((SKIP_UV == 1)); then
		step_skip "${CURRENT_STEP}" "Tool 'uv' not selected"
		return 0
	fi

	if ! have_cmd "uv"; then
		warn "uv not found."
		warn "Remediation: verify with 'command -v uv' and 'uv --version'. Install uv using your original install method, then re-run."
		step_fail_optional "${CURRENT_STEP}" "uv missing"
		return 0
	fi

	export UV_NO_MODIFY_PATH=1

	local self_rc tools_rc self_state tools_state lower_out
	self_state="ok"
	tools_state="ok"
	self_rc=0
	tools_rc=0

	if ! run_cmd_optional_capture uv self update; then
		self_rc=$?
		self_state="failed"
		warn "uv self update failed (exit ${self_rc})."

		lower_out=""
		if ((DRY_RUN == 0)); then
			# Heuristic: if self-update is disabled, do not count as a failure unless --strict.
			# Use captured output from the failed attempt to avoid re-running update logic.
			lower_out="$(printf '%s' "${LAST_CMD_OUT}" | tr '[:upper:]' '[:lower:]')"
			if [[ "${lower_out}" == *"self"* && "${lower_out}" == *"update"* && "${lower_out}" == *"disable"* ]]; then
				self_state="disabled"
				warn "Hint: uv self update appears disabled. Upgrade uv via its original installation method, then re-run if desired."
			fi
		else
			warn "Hint: if uv self update is disabled, upgrade uv via its original installation method."
		fi

		if [[ "${self_state}" == "failed" ]]; then
			if ((STRICT == 1)); then
				step_fail_optional "${CURRENT_STEP}" "uv self update failed"
				return 0
			fi
		fi
	fi

	if ! run_cmd_optional_capture uv tool upgrade --all; then
		tools_rc=$?
		tools_state="failed"
		warn "uv tool upgrade --all failed (exit ${tools_rc})."
	fi

	if [[ "${tools_state}" == "ok" ]] && [[ "${self_state}" != "failed" ]]; then
		step_ok "${CURRENT_STEP}" "self=${self_state}, tools=ok"
	else
		# If self-update is disabled but tools succeeded, treat as OK.
		if [[ "${self_state}" == "disabled" ]] && [[ "${tools_state}" == "ok" ]]; then
			step_ok "${CURRENT_STEP}" "self=disabled, tools=ok"
		else
			step_fail_optional "${CURRENT_STEP}" "self=${self_state}, tools=${tools_state}"
		fi
	fi
}

claude_update() {
	step_begin "Claude update"

	if ((SKIP_CLAUDE == 1)); then
		step_skip "${CURRENT_STEP}" "Tool 'claude' not selected"
		return 0
	fi

	if ! have_cmd "claude"; then
		warn "claude not found."
		warn "Remediation: verify with 'command -v claude' and 'claude --version'. Install Claude Code using your original install method, then re-run."
		step_fail_optional "${CURRENT_STEP}" "claude missing"
		return 0
	fi

	local old_ver new_ver update_rc version_changed up_to_date
	old_ver=""
	new_ver=""
	update_rc=0
	version_changed="unknown"
	up_to_date=0

	if ((DRY_RUN == 1)); then
		log "DRY-RUN: claude --version"
		log "DRY-RUN: claude update"
		log "DRY-RUN: claude --version"
		step_ok "${CURRENT_STEP}" "dry-run"
		return 0
	fi

	if ! old_ver="$(claude --version 2>&1 | head -n 1)"; then
		old_ver="(unable to read version)"
	fi
	log "Claude version before update: ${old_ver}"

	if ! run_cmd_optional_capture claude update; then
		update_rc=$?
		warn "claude update failed (exit ${update_rc})."
	fi

	# Treat "up to date" from the updater as success, even if the version string does not change.
	if [[ -n "${LAST_CMD_OUT}" ]] && printf '%s' "${LAST_CMD_OUT}" | grep -qiE 'up to date|already up[ -]?to[ -]?date'; then
		up_to_date=1
	fi

	if ! new_ver="$(claude --version 2>&1 | head -n 1)"; then
		new_ver="(unable to read version)"
	fi
	log "Claude version after update: ${new_ver}"

	if [[ "${old_ver}" != "${new_ver}" ]]; then
		version_changed="yes"
	else
		version_changed="no"
	fi

	if ((update_rc == 0)) && ((up_to_date == 1)); then
		step_ok "${CURRENT_STEP}" "up-to-date (${new_ver})"
		return 0
	fi

	if ((update_rc == 0)) && [[ "${version_changed}" == "yes" ]]; then
		step_ok "${CURRENT_STEP}" "${new_ver}"
		return 0
	fi

	warn "Claude update may not have applied (update_rc=${update_rc}, version_changed=${version_changed})."
	warn "Remediation hints:"
	warn "- Identify which binary is used: 'command -v claude' and 'ls -l \$(command -v claude)'."
	warn "- Common locations: ~/.local/bin/claude, /usr/local/bin/claude"
	warn "- If installed via winget on Windows, use a winget upgrade workflow (for example: 'winget upgrade')."
	warn "- Otherwise, upgrade via the same method you originally installed Claude Code (package manager, installer, or manual binary)."
	step_fail_optional "${CURRENT_STEP}" "update_rc=${update_rc}, version_changed=${version_changed}"
}

codex_update() {
	step_begin "Codex update"

	if ((SKIP_CODEX == 1)); then
		step_skip "${CURRENT_STEP}" "Tool 'codex' not selected"
		return 0
	fi

	if ! have_cmd "volta"; then
		warn "volta not found."
		warn "Remediation: verify with 'command -v volta' and 'volta --version'. Install Volta (https://volta.sh), then re-run."
		step_skip "${CURRENT_STEP}" "volta missing"
		return 0
	fi

	if ! have_cmd "codex"; then
		warn "codex not found."
		warn "Remediation: verify with 'command -v codex'. Install Codex first using 'volta install @openai/codex@latest', then re-run."
		step_skip "${CURRENT_STEP}" "codex missing"
		return 0
	fi

	local old_ver new_ver install_rc installed_semver latest_semver
	old_ver=""
	new_ver=""
	install_rc=0
	installed_semver=""
	latest_semver=""

	if ((DRY_RUN == 1)); then
		log "DRY-RUN: codex --version"
		log "DRY-RUN: volta install @openai/codex@latest"
		log "DRY-RUN: codex --version"
		step_ok "${CURRENT_STEP}" "dry-run"
		return 0
	fi

	if ! old_ver="$(codex --version 2>&1 | head -n 1)"; then
		old_ver="(unable to read version)"
	fi
	log "Codex version before update: ${old_ver}"

	if installed_semver="$(extract_first_semver "${old_ver}")"; then
		if latest_semver="$(latest_codex_version_from_npm)"; then
			log "Latest Codex version available from npm: ${latest_semver}"
			if [[ "${installed_semver}" == "${latest_semver}" ]]; then
				step_ok "${CURRENT_STEP}" "up-to-date (${old_ver})"
				return 0
			fi
		else
			log "Codex latest-version pre-check unavailable; falling back to install check."
		fi
	else
		log "Unable to parse current Codex version; falling back to install check."
	fi

	if ! run_cmd_optional_capture volta install @openai/codex@latest; then
		install_rc=$?
		warn "volta install @openai/codex@latest failed (exit ${install_rc})."
		step_fail_optional "${CURRENT_STEP}" "volta install failed (exit ${install_rc})"
		return 0
	fi

	if ! new_ver="$(codex --version 2>&1 | head -n 1)"; then
		new_ver="(unable to read version)"
	fi
	log "Codex version after update: ${new_ver}"

	if [[ "${old_ver}" == "${new_ver}" ]]; then
		step_ok "${CURRENT_STEP}" "up-to-date (${new_ver})"
	else
		step_ok "${CURRENT_STEP}" "${old_ver} -> ${new_ver}"
	fi
}

trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
trap 'on_exit $?' EXIT

main() {
	parse_args "$@"

	if ((LIST_TOOLS == 1)); then
		SKIP_SUMMARY=1
		print_tool_catalog
		exit 0
	fi

	load_config
	resolve_tool_selection

	acquire_lock
	validate_fedora
	validate_passwordless_sudo

	dnf_system_update
	baseline_dnf_bootstrap
	volta_node_update
	uv_update
	claude_update
	codex_update

	log "All requested steps completed."
	exit 0
}

main "$@"
