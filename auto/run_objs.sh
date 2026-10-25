#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# DEFAULT CONFIGURATION — can all be overridden via CLI args
# ============================================================
DEFAULT_PROGRAM="odin run . --debug --"
DEFAULT_DIR="."
DEFAULT_TIMEOUT="3s"
DEFAULT_KILL_AFTER="0.1s"
DEFAULT_LOG_DIR="."
DEFAULT_PATTERN="*"             # Match all regular files
DEFAULT_RECURSIVE=false
DEFAULT_VERBOSE=false

# ============================================================
# HELP
# ============================================================
usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -d, --dir DIR           Directory containing input files (default: $DEFAULT_DIR)
  -p, --program COMMAND   Command to run (default: "$DEFAULT_PROGRAM")
  -t, --timeout TIME      Per-file time limit (default: $DEFAULT_TIMEOUT)
  -k, --kill-after TIME   Force kill after timeout grace period (default: $DEFAULT_KILL_AFTER)
  -l, --log-dir DIR       Directory for log files (default: $DEFAULT_LOG_DIR)
  -g, --glob PATTERN      File-name glob (default: "$DEFAULT_PATTERN")
  -r, --recursive         Include files in subdirectories
  -v, --verbose           Print each command before running
  -h, --help              Show this help

Examples:
  $0 --dir ../../../assets
  $0 -d ./meshes -t 1000ms
  $0 -d ./meshes -g '*.obj' -t 2s -l ./logs
  $0 -d ./meshes -r -t 500ms

Notes:
  - Exit code 0 means PASS.
  - Timeouts and nonzero exit codes count as FAIL.
  - Each run writes stdout and stderr to its own log.
  - TIME supports ms, s, m, h (GNU timeout).
EOF
}

# ============================================================
# ARGUMENT PARSING
# ============================================================
DIR="$DEFAULT_DIR"
PROGRAM="$DEFAULT_PROGRAM"
TIMEOUT="$DEFAULT_TIMEOUT"
KILL_AFTER="$DEFAULT_KILL_AFTER"
LOG_DIR="$DEFAULT_LOG_DIR"
PATTERN="$DEFAULT_PATTERN"
RECURSIVE="$DEFAULT_RECURSIVE"
VERBOSE="$DEFAULT_VERBOSE"

while (($#)); do
    case "$1" in
        -d|--dir)        DIR="${2:?Missing directory}"; shift 2 ;;
        -p|--program)    PROGRAM="${2:?Missing command}"; shift 2 ;;
        -t|--timeout)    TIMEOUT="${2:?Missing timeout}"; shift 2 ;;
        -k|--kill-after) KILL_AFTER="${2:?Missing kill-after duration}"; shift 2 ;;
        -l|--log-dir)    LOG_DIR="${2:?Missing log directory}"; shift 2 ;;
        -g|--glob)       PATTERN="${2:?Missing glob}"; shift 2 ;;
        -r|--recursive)  RECURSIVE=true; shift ;;
        -v|--verbose)    VERBOSE=true; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ============================================================
# VALIDATION
# ============================================================
if [[ ! -d "$DIR" ]]; then
    echo "Error: input directory does not exist: $DIR" >&2
    exit 2
fi

if ! command -v timeout >/dev/null 2>&1; then
    echo "Error: GNU timeout is required." >&2
    exit 2
fi

if ! mkdir -p "$LOG_DIR"; then
    echo "Error: cannot create log directory: $LOG_DIR" >&2
    exit 2
fi

# Split the command into arguments. This supports ordinary commands
# with flags, but not shell syntax, pipes, or quoted argument grouping.
read -r -a CMD <<< "$PROGRAM"

if ((${#CMD[@]} == 0)); then
    echo "Error: empty program command." >&2
    exit 2
fi

# ============================================================
# DISCOVER INPUT FILES
# ============================================================
FILES=()

if [[ "$RECURSIVE" == true ]]; then
    while IFS= read -r -d '' file; do
        FILES+=("$file")
    done < <(find "$DIR" -type f -name "$PATTERN" -print0 | sort -z)
else
    while IFS= read -r -d '' file; do
        FILES+=("$file")
    done < <(find "$DIR" -maxdepth 1 -type f -name "$PATTERN" -print0 | sort -z)
fi

TOTAL=${#FILES[@]}

if ((TOTAL == 0)); then
    echo "No files matching '$PATTERN' found in: $DIR"
    exit 0
fi

# ============================================================
# RUN TESTS
# ============================================================
PASS=0
FAIL=0
TIMED_OUT=0
FAILED_FILES=()
TIMED_OUT_FILES=()

printf '\n'
printf '============================================================\n'
printf '                  INPUT TEST RUNNER                         \n'
printf '============================================================\n'
printf ' Directory : %s\n' "$DIR"
printf ' Program   : %s\n' "$PROGRAM"
printf ' Timeout   : %s\n' "$TIMEOUT"
printf ' Kill after: %s\n' "$KILL_AFTER"
printf ' Log dir   : %s\n' "$LOG_DIR"
printf ' Pattern   : %s\n' "$PATTERN"
printf ' Recursive : %s\n' "$RECURSIVE"
printf ' Total     : %d files\n' "$TOTAL"
printf '============================================================\n\n'

for file in "${FILES[@]}"; do
    name=$(basename "$file")
    log="$LOG_DIR/log_${name}.tmp"

    # Use a relative path only if that is what was discovered.
    # Absolute paths are safer if the program changes directories.
    if [[ "$file" != /* ]]; then
        arg="./$file"
    else
        arg="$file"
    fi

    if [[ "$VERBOSE" == true ]]; then
        printf 'RUN:'
        printf ' %q' "${CMD[@]}" "$arg"
        printf '\n'
    fi

    # timeout returns 124 on timeout. -k ensures SIGKILL after
    # the grace period if the process doesn't stop on SIGTERM.
    timeout --kill-after="$KILL_AFTER" "$TIMEOUT" \
        "${CMD[@]}" "$arg" >"$log" 2>&1
    status=$?

    if ((status == 0)); then
        ((PASS+=1))
        printf ' [PASS] %s\n' "$file"
    elif ((status == 124 || status == 137)); then
        ((FAIL+=1))
        ((TIMED_OUT+=1))
        TIMED_OUT_FILES+=("$file")
        printf ' [TIMEOUT] %s\n' "$file"
    else
        ((FAIL+=1))
        FAILED_FILES+=("$file")
        printf ' [FAIL] %s (exit %d)\n' "$file" "$status"
    fi
done

# ============================================================
# SUMMARY
# ============================================================
printf '\n'
printf '============================================================\n'
printf '                       SUMMARY                              \n'
printf '============================================================\n'
printf ' Total     : %d\n' "$TOTAL"
printf ' Passed    : %d\n' "$PASS"
printf ' Failed    : %d\n' "$FAIL"
printf ' Timed out : %d\n' "$TIMED_OUT"
printf '============================================================\n'

if ((${#FAILED_FILES[@]})); then
    printf '\nFailed files:\n'
    printf '  - %s\n' "${FAILED_FILES[@]}"
fi

if ((${#TIMED_OUT_FILES[@]})); then
    printf '\nTimed-out files:\n'
    printf '  - %s\n' "${TIMED_OUT_FILES[@]}"
fi

printf '\nLogs saved to: %s\n' "$LOG_DIR"

if ((FAIL > 0)); then
    exit 1
fi

exit 0
