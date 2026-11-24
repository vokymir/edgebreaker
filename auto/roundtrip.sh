#!/usr/bin/env bash
#
# roundtrip.sh - batch compress/decompress test for the edgebreaker `ebk` tool.
#
# 1. Builds src/cmd/ebk ONCE (odin build) inside a scratch tmp folder.
# 2. For every mesh below the mesh root (default: assets/fetched/meshes; folders
#    starting with "_" such as _downloads are skipped) in any format ebk can encode
#    (read from `ebk -formats`) runs  mesh -> encoded -> obj. Other files are only
#    counted and listed under "Skipped files".
#    All intermediate files live in the scratch folder, which is deleted at the end.
# 3. A step FAILS when the exit code is non-zero, it times out, or its output file
#    is missing/empty. The last non-empty line the program printed (usually the
#    assert) is normalised and used to group the failures.
# 4. Prints a summary with percentages and writes logs/roundtrip_<timestamp>.log
#    (+ a .tsv with one row per mesh).
#
# Usage:   ./roundtrip.sh [options] [MESH_DIR]
# Run from Git Bash (or any bash >= 4.4) with `odin` on PATH.
#
# Options:
#   -c, --codec NAME     vertex codec used for encoding        (names: ebk -codecs)
#   -d, --decoder NAME   decoder used for decoding             (names: ebk -decoders)
#   -f, --format KIND    encoded format: simple | binary       (or an extension, e.g. .ebk)
#   --pause, --no-pause  wait for Enter before the window closes (default: automatic,
#                        i.e. only when started from a window that would vanish)
#   -h, --help           show this help
#   Without --format each input format uses its default pair from `ebk -formats`.
#   --codec/--decoder names are checked against the tool and matched case-insensitively.
#
# Optional environment variables:
#   ROOT          repo root (default: auto-detected from the script location)
#   ODIN_FLAGS    flags for odin build           (default: -o:speed)
#   TIMEOUT_SEC   per-step timeout, 0 = none     (default: 120)
#   FILTER        only meshes whose path contains this text (case-insensitive)
#   MAX_FILES     only test the first N meshes   (default: 0 = all)
#   MASK_NUMBERS  1 = replace numbers in messages by N when grouping (default: 0)
#   LOG_DIR       where logs go                  (default: <script dir>/logs)
#   KEEP_TMP      1 = keep the scratch folder (incl. raw output of failed runs)
#   PAUSE         1 / 0 = same as --pause / --no-pause
#   CODEC, DECODER, FORMAT, ENC_EXT  same as the flags (flags win)

set -uo pipefail
export MSYS2_ARG_CONV_EXCL='*'   # Git Bash: never rewrite our arguments
export LC_ALL=C

# ---- wrapper -----------------------------------------------------------------
# Re-runs this script with all output copied to logs/roundtrip_<stamp>.console.txt
# (so nothing is lost, even for early errors) and, when it was started in a window
# that would vanish on exit (e.g. `.\roundtrip.sh` from PowerShell), waits for Enter.
# --pause / --no-pause or PAUSE=1 / PAUSE=0 override the automatic detection.
if [[ -z ${ROUNDTRIP_INNER:-} ]]; then
  _self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
  _logdir=${LOG_DIR:-$(dirname "$_self")/logs}
  mkdir -p "$_logdir" 2>/dev/null
  export ROUNDTRIP_STAMP
  ROUNDTRIP_STAMP=$(date +%Y%m%d_%H%M%S)
  _console=$_logdir/roundtrip_$ROUNDTRIP_STAMP.console.txt

  _pause=${PAUSE:-auto}
  for _a in "$@"; do
    case $_a in --pause) _pause=1;; --no-pause) _pause=0;; esac
  done
  if [[ $_pause == auto ]]; then
    _pause=0
    if [[ -t 0 ]] && { [[ $- == *i* ]] || (( ${SHLVL:-1} <= 1 )); }; then _pause=1; fi
  fi

  ROUNDTRIP_INNER=1 "$BASH" "$_self" "$@" 2>&1 | tee -i "$_console"
  _rc=${PIPESTATUS[0]}

  echo
  echo "Finished with exit code $_rc.  Console output saved to: $_console"
  if [[ $_pause == 1 ]]; then
    read -r -p "Press Enter to close this window... " _ || true
  fi
  exit "$_rc"
fi
# ---- end wrapper -------------------------------------------------------------

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) \
  || die "bash >= 4.4 is required"
for tool in odin find awk sed sort tr; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found in PATH"
done

# ------------------------------------------------------------------ config ----

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -z ${ROOT:-} ]]; then
  if [[ -d $SCRIPT_DIR/src/cmd/ebk ]]; then ROOT=$SCRIPT_DIR; else ROOT=$(cd "$SCRIPT_DIR/.." && pwd); fi
fi
[[ -d $ROOT/src/cmd/ebk ]] || die "cannot find src/cmd/ebk under $ROOT (set ROOT=...)"

CODEC=${CODEC:-}
DECODER=${DECODER:-}
FORMAT=${FORMAT:-}
ENC_EXT=${ENC_EXT:-}

usage() {
  cat <<'EOF'
Usage: roundtrip.sh [options] [MESH_DIR]

  -c, --codec NAME     vertex codec used for encoding   (names: ebk -codecs)
  -d, --decoder NAME   decoder used for decoding        (names: ebk -decoders)
  -f, --format KIND    encoded format: simple | binary  (or an extension, e.g. .ebk)
  --pause, --no-pause  wait for Enter at the end (default: automatic)
  -h, --help           show this help

MESH_DIR defaults to assets/fetched/meshes. See the top of the script for the
environment variables (FILTER, MAX_FILES, TIMEOUT_SEC, ...).
EOF
}

MESH_ARG=""
while (( $# )); do
  case $1 in
    -c|--codec|-d|--decoder|-f|--format)
      (( $# >= 2 )) || die "$1 needs a value (see --help)"
      case $1 in -c|--codec) CODEC=$2;; -d|--decoder) DECODER=$2;; *) FORMAT=$2;; esac
      shift 2;;
    --codec=*)   CODEC=${1#*=};   shift;;
    --decoder=*) DECODER=${1#*=}; shift;;
    --format=*)  FORMAT=${1#*=};  shift;;
    --pause|--no-pause) shift;;   # handled by the wrapper
    -h|--help)   usage; exit 0;;
    -*)          die "unknown option: $1 (see --help)";;
    *)           [[ -z $MESH_ARG ]] || die "only one MESH_DIR is allowed"; MESH_ARG=$1; shift;;
  esac
done

FORMAT=${FORMAT,,}
case $FORMAT in
  ""|simple|binary|.*) ;;
  *) die "--format must be 'simple', 'binary' or an extension like .ebk (got '$FORMAT')";;
esac

MESH_ROOT=${MESH_ARG:-$ROOT/assets/fetched/meshes}
[[ -d $MESH_ROOT ]] || die "mesh directory not found: $MESH_ROOT"
MESH_ROOT=$(cd "$MESH_ROOT" && pwd)

ODIN_FLAGS=${ODIN_FLAGS:--o:speed}
TIMEOUT_SEC=${TIMEOUT_SEC:-120}
FILTER=${FILTER:-}
MAX_FILES=${MAX_FILES:-0}
MASK_NUMBERS=${MASK_NUMBERS:-0}
KEEP_TMP=${KEEP_TMP:-0}
LOG_DIR=${LOG_DIR:-$SCRIPT_DIR/logs}

# Native (Windows-style) paths for the odin toolchain when running in Git Bash.
if command -v cygpath >/dev/null 2>&1; then
  to_native() { cygpath -m -- "$1"; }
  EXE_SUFFIX=.exe
else
  to_native() { printf '%s' "$1"; }
  EXE_SUFFIX=
fi

# Use GNU timeout only (Windows ships an unrelated timeout.exe).
TIMEOUT_CMD=()
if (( TIMEOUT_SEC > 0 )) && timeout --version 2>/dev/null | grep -qi coreutils; then
  TIMEOUT_CMD=(timeout "$TIMEOUT_SEC")
fi

ESC=$'\033'
INTERRUPTED=0
trap 'INTERRUPTED=1' INT

# ----------------------------------------------------------- tmp + cleanup ----

STAMP=${ROUNDTRIP_STAMP:-$(date +%Y%m%d_%H%M%S)}
mkdir -p "$ROOT/tmp" "$LOG_DIR" || die "cannot create tmp/log folders"
LOG_DIR=$(cd "$LOG_DIR" && pwd)
WORK_DIR=$(mktemp -d "$ROOT/tmp/roundtrip.XXXXXX") || die "cannot create scratch folder"
LOG_FILE=$LOG_DIR/roundtrip_$STAMP.log
TSV_FILE=$LOG_DIR/roundtrip_$STAMP.tsv
RESULTS=$WORK_DIR/results.tsv   # mesh <TAB> encode <TAB> decode <TAB> reason

cleanup() {
  cd "$ROOT" 2>/dev/null || cd /
  if [[ ${KEEP_TMP} == 1 ]]; then
    echo "Scratch folder kept: $WORK_DIR"
  else
    rm -rf -- "$WORK_DIR"
    rmdir "$ROOT/tmp" 2>/dev/null || true   # only succeeds if empty
  fi
}
trap cleanup EXIT

: >"$RESULTS"
mkdir -p "$WORK_DIR/failed"


# --------------------------------------------------------------------- build ----

cd "$WORK_DIR" || die "cannot enter $WORK_DIR"
echo "Building ebk (odin build $ODIN_FLAGS) ..."
read -r -a ODIN_FLAG_ARR <<<"$ODIN_FLAGS"
if ! odin build "$(to_native "$ROOT/src/cmd/ebk")" "-out:ebk$EXE_SUFFIX" "${ODIN_FLAG_ARR[@]}" >build.log 2>&1; then
  cat build.log >&2
  die "odin build failed"
fi
EBK=./ebk$EXE_SUFFIX

# canon_name <ebk list flag> <label> <value>: the tool's own spelling of a codec/decoder name.
canon_name() {
  local flag=$1 label=$2 want=$3 avail name
  avail=$("$EBK" "$flag" 2>/dev/null | tr -d '\r' | awk '/^  [^ ]/ { printf "%s%s", sep, $1; sep = " " }')
  if [[ -z $avail ]]; then printf '%s' "$want"; return; fi   # cannot validate, pass through
  for name in $avail; do
    if [[ ${name,,} == "${want,,}" ]]; then printf '%s' "$name"; return; fi
  done
  die "unknown $label '$want' (available: ${avail// /, })"
}

# format_ext <simple|binary>: extension of the matching Decode row in `ebk -formats`.
format_ext() {
  "$EBK" -formats 2>/dev/null | tr -d '\r' | awk -v kind="$1" '
    $1 ~ /^\./ && $(NF - 1) == "Decode" {
      is_simple = (tolower($0) ~ /simple/)
      if ((kind == "simple") == is_simple) { print $1; exit }
    }'
}

[[ -z $CODEC   ]] || CODEC=$(canon_name -codecs codec "$CODEC")       || exit 2
[[ -z $DECODER ]] || DECODER=$(canon_name -decoders decoder "$DECODER") || exit 2

# Supported formats according to the tool itself: PAIR_OF[ext] = default pair,
# INPUT_EXTS = every format that can be encoded (e.g. .obj, and whatever else ebk learns).
declare -A PAIR_OF=()
INPUT_EXTS=()
while IFS=$'\t' read -r _e _op _pair; do
  [[ -n $_e ]] || continue
  PAIR_OF[$_e]=$_pair
  [[ $_op == Encode ]] && INPUT_EXTS+=("$_e")
done < <("$EBK" -formats 2>/dev/null | tr -d '\r' \
         | awk '$1 ~ /^\./ && NF >= 3 { print tolower($1) "\t" $(NF - 1) "\t" tolower($NF) }')
if (( ${#INPUT_EXTS[@]} == 0 )); then
  echo "warning: could not read the format table from 'ebk -formats', assuming .obj -> .ebk" >&2
  INPUT_EXTS=(.obj); PAIR_OF[.obj]=.ebk
fi

# Encoded format: --format/ENC_EXT fixes it for every mesh, otherwise each input
# format uses its own default pair.
ENC_EXT=${ENC_EXT,,}
if [[ -z $ENC_EXT ]]; then
  case $FORMAT in
    simple|binary)
      ENC_EXT=$(format_ext "$FORMAT")
      if [[ -z $ENC_EXT ]]; then
        "$EBK" -formats >&2
        die "no '$FORMAT' format found in 'ebk -formats'; pass an extension, e.g. --format .ebk"
      fi ;;
    .*) ENC_EXT=$FORMAT ;;
  esac
fi

# ------------------------------------------------------------ collect meshes ----
# Everything below MESH_ROOT except folders starting with "_", for every input
# format the tool supports. Other files are only counted (see "Skipped files").

find_expr=()
for _e in "${INPUT_EXTS[@]}"; do find_expr+=(-o -iname "*$_e"); done
find_expr=("${find_expr[@]:1}")

mapfile -d '' -t files < <(
  find "$MESH_ROOT" -mindepth 1 -type d -name '_*' -prune -o \
       -type f \( "${find_expr[@]}" \) -ipath "*${FILTER}*" -print0 | sort -z
)
SKIPPED=$WORK_DIR/skipped.tsv   # count <TAB> extension
find "$MESH_ROOT" -mindepth 1 -type d -name '_*' -prune -o \
     -type f ! \( "${find_expr[@]}" \) -ipath "*${FILTER}*" -print0 | tr '\0' '\n' \
  | awk '{ n = split($0, p, "/"); f = p[n]; i = match(f, /\.[^.]*$/)
           e = i ? tolower(substr(f, i)) : "(no extension)"; c[e]++ }
         END { for (e in c) printf "%d\t%s\n", c[e], e }' | sort -t$'\t' -k1,1nr -k2 >"$SKIPPED"

if (( MAX_FILES > 0 && ${#files[@]} > MAX_FILES )); then
  files=("${files[@]:0:MAX_FILES}")
fi
total=${#files[@]}
(( total > 0 )) || die "no files with a supported input format (${INPUT_EXTS[*]}) found under $MESH_ROOT"

CODEC_ARG=();   [[ -n $CODEC   ]] && CODEC_ARG=("-codec:$CODEC")
DECODER_ARG=(); [[ -n $DECODER ]] && DECODER_ARG=("-decoder:$DECODER")

echo "Meshes: $total   root: $MESH_ROOT"
echo "Input formats: ${INPUT_EXTS[*]}   encoded format: ${ENC_EXT:-default pair of each input format}"
echo "Codec: ${CODEC:-default}   decoder: ${DECODER:-default}"
if [[ -s $SKIPPED ]]; then
  echo "Skipped (not an ebk input format): $(awk -F'\t' '{ printf "%s%d x %s", s, $1, $2; s = ", " }' "$SKIPPED")"
fi
echo

# ------------------------------------------------------------------- helpers ----

# run_ebk <logfile> <args...>   -> output of the program goes to <logfile>, exit code in RC
run_ebk() {
  local logf=$1; shift
  "${TIMEOUT_CMD[@]}" "$EBK" "$@" >"$logf" 2>&1
  RC=$?
}

# fail_reason <logfile> <rc> <input-path>
# Prints the last non-empty output line, cleaned up so equal failures group together.
fail_reason() {
  local logf=$1 rc=$2 input=$3 line msg
  local re='^([^[:space:]]+\([0-9]+:[0-9]+\))[[:space:]](.*)$'

  if (( rc == 124 && ${#TIMEOUT_CMD[@]} > 0 )); then
    printf 'TIMEOUT (> %ss)' "$TIMEOUT_SEC"
    return
  fi

  line=$(tr -d '\r' <"$logf" | sed -E "s/${ESC}\[[0-9;]*[A-Za-z]//g" | awk 'NF { l = $0 } END { print l }')
  line=${line//"$input"/<input>}                       # drop the mesh path
  line=$(printf '%s' "$line" | sed -E \
      -e 's#([A-Za-z]:)?[^[:space:]()]*[/\\]([^/\\[:space:]()]+\.odin)#\2#g' \
      -e 's/\[[0-9]{4}-[0-9]{2}-[0-9]{2}[^]]*\] ?//g' \
      -e 's/[[:space:]]+/ /g; s/^ //; s/ $//')         # short paths, no timestamps

  if (( MASK_NUMBERS )); then                          # keep the (line:col) of the assert
    if [[ $line =~ $re ]]; then
      msg=$(printf '%s' "${BASH_REMATCH[2]}" | sed -E 's/[0-9]+/N/g')
      line="${BASH_REMATCH[1]} $msg"
    else
      line=$(printf '%s' "$line" | sed -E 's/[0-9]+/N/g')
    fi
  fi

  if [[ -z $line ]]; then
    if (( rc == 0 )); then line="exit code 0 but no output file produced"
    else line="no output at all (exit code $rc)"; fi
  fi
  printf '%s' "${line:0:200}"
}

# ------------------------------------------------------------------ main loop ----

idx=0
for f in "${files[@]}"; do
  (( INTERRUPTED )) && break
  idx=$((idx + 1))
  rel=${f#"$MESH_ROOT"/}
  in_native=$(to_native "$f")
  ext=.${f##*.}; ext=${ext,,}
  enc_ext=${ENC_EXT:-${PAIR_OF[$ext]:-.ebk}}
  dec_ext=${PAIR_OF[$enc_ext]:-.obj}
  enc_file=enc$enc_ext; dec_file=dec$dec_ext
  rm -f -- enc.* dec.*
  printf '[%*d/%d] %s ... ' "${#total}" "$idx" "$total" "$rel"

  enc=OK dec=SKIP reason=""
  run_ebk enc.log "$in_native" "-out:$enc_file" "${CODEC_ARG[@]}"
  if (( RC != 0 )) || [[ ! -s $enc_file ]]; then
    enc=FAIL
    reason=$(fail_reason enc.log "$RC" "$in_native")
  else
    dec=OK
    run_ebk dec.log "$enc_file" "-out:$dec_file" "${DECODER_ARG[@]}"
    if (( RC != 0 )) || [[ ! -s $dec_file ]]; then
      dec=FAIL
      reason=$(fail_reason dec.log "$RC" "$in_native")
    fi
  fi

  if (( INTERRUPTED )); then echo "interrupted"; break; fi

  if   [[ $enc == FAIL ]]; then cp enc.log "failed/${rel//\//__}.encode.log"
  elif [[ $dec == FAIL ]]; then cp dec.log "failed/${rel//\//__}.decode.log"; fi

  if   [[ $enc == OK && $dec == OK ]]; then echo "OK"
  elif [[ $enc == FAIL ]];            then echo "FAIL (encode): ${reason:0:110}"
  else                                     echo "FAIL (decode): ${reason:0:110}"; fi

  printf '%s\t%s\t%s\t%s\n' "$rel" "$enc" "$dec" "$reason" >>"$RESULTS"
done

# -------------------------------------------------------------------- report ----

print_summary() {
  awk -F'\t' '
    function pct(a, b) { return b ? sprintf("%.1f%%", 100 * a / b) : "n/a" }
    { n++ }
    $2 == "OK" { enc_ok++ }
    $3 == "OK" { dec_ok++ }
    $2 == "OK" && $3 == "OK" { ok++ }
    END {
      printf "Meshes tested:  %d\n", n
      printf "Fully OK:       %d/%d  (%s)\n", ok, n, pct(ok, n)
      printf "Encode OK:      %d/%d  (%s)\n", enc_ok, n, pct(enc_ok, n)
      printf "Decode OK:      %d/%d  (%s of those that encoded)\n", dec_ok, enc_ok, pct(dec_ok, enc_ok)
    }' "$RESULTS"
}

print_collections() {
  awk -F'\t' '
    function pct(a, b) { return b ? sprintf("%.1f%%", 100 * a / b) : "n/a" }
    { i = index($1, "/"); c = i ? substr($1, 1, i - 1) : "."; tot[c]++
      if ($2 == "OK" && $3 == "OK") good[c]++ }
    END { for (c in tot) printf "  %-22s %5d/%-5d  %s\n", c, good[c], tot[c], pct(good[c], tot[c]) }
  ' "$RESULTS" | sort
}

# print_failures <label> <column: 2=encode 3=decode> <with_files 0|1>
print_failures() {
  local label=$1 col=$2 with_files=$3 n count reason
  n=$(awk -F'\t' -v c="$col" '$c == "FAIL"' "$RESULTS" | wc -l)
  (( n > 0 )) || return 0
  echo "-- $label failures: $n --"
  awk -F'\t' -v c="$col" '$c == "FAIL" { k[$4]++ } END { for (r in k) printf "%d\t%s\n", k[r], r }' "$RESULTS" \
    | sort -t$'\t' -k1,1nr -k2 \
    | while IFS=$'\t' read -r count reason; do
        printf '[%dx] %s\n' "$count" "$reason"
        if (( with_files )); then
          R=$reason awk -F'\t' -v c="$col" '$c == "FAIL" && $4 == ENVIRON["R"] { print "      - " $1 }' "$RESULTS" | sort
        fi
      done
  echo
}

# write_report <with_files 0|1> <with_ok_list 0|1>
write_report() {
  local with_files=$1 with_ok=$2 nfail
  echo "== Summary =="
  print_summary
  echo
  echo "== By collection (first folder under the mesh root) =="
  print_collections
  echo
  if [[ -s $SKIPPED ]]; then
    echo "== Skipped files (extension is not an ebk input format: ${INPUT_EXTS[*]}) =="
    awk -F'\t' '{ printf "  %6d x %s\n", $1, $2 }' "$SKIPPED"
    echo
  fi
  echo "== Failures grouped by last output line =="
  nfail=$(awk -F'\t' '$2 == "FAIL" || $3 == "FAIL"' "$RESULTS" | wc -l)
  if (( nfail == 0 )); then
    echo "(none)"
  else
    (( with_files )) || echo "(mesh names per failure: see the log file)"
    print_failures ENCODE 2 "$with_files"
    print_failures DECODE 3 "$with_files"
  fi
  if (( with_ok )); then
    echo
    echo "== Meshes that passed the full round trip =="
    awk -F'\t' '$2 == "OK" && $3 == "OK" { print "  " $1 }' "$RESULTS" | sort
  fi
}

elapsed="$((SECONDS / 60))m$((SECONDS % 60))s"
{
  echo "Edgebreaker round-trip test"
  echo "  date:          $(date '+%Y-%m-%d %H:%M:%S')   (took $elapsed)"
  echo "  mesh root:     $MESH_ROOT"
  echo "  odin flags:    $ODIN_FLAGS"
  echo "  input formats: ${INPUT_EXTS[*]}"
  echo "  encoded as:    ${ENC_EXT:-default pair of each input format}"
  echo "  codec:         ${CODEC:-default}"
  echo "  decoder:       ${DECODER:-default}"
  echo "  timeout:       ${TIMEOUT_SEC}s"
  (( INTERRUPTED )) && echo "  NOTE: run was interrupted, results are partial"
  echo "  per-mesh table: ${TSV_FILE##*/}  (columns: mesh, encode, decode, reason)"
  echo
  write_report 1 1
} >"$LOG_FILE"
cp "$RESULTS" "$TSV_FILE"

echo
echo "=============================================================="
write_report 0 0
echo "Took $elapsed.  Full log: $LOG_FILE"

nfail=$(awk -F'\t' '$2 == "FAIL" || $3 == "FAIL"' "$RESULTS" | wc -l)
(( nfail == 0 && INTERRUPTED == 0 ))
