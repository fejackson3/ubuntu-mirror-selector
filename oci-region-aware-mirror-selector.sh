#!/usr/bin/env bash
# oci-region-aware-mirror-selector.sh
# Detects OCI region, collects mirrors (mirrors.ubuntu.com + Launchpad),
# prioritizes region-local mirrors, measures real download throughput,
# updates apt sources, logs audit info.
# Target: Ubuntu 22.04 and 24.04
# Usage: sudo ./oci-region-aware-mirror-selector.sh
set -euo pipefail

# -----------------------
# Configuration
# -----------------------
LOGFILE="/var/log/oci-mirror-selector.log"
INFOFILE="/etc/cloud/mirror-info.txt"
CUSTOM_LIST="/etc/mirrorlist.custom"         # optional file (one URL per line)
TMPDIR="$(mktemp -d /tmp/oci-mirror-XXXX)"
TEST_FILE_PATH="dists/$(lsb_release -cs)/Release"  # small metadata file exists on all mirrors
CONCURRENT_JOBS=6
TEST_SAMPLE_COUNT=12     # number of mirrors to test (after prioritization)
TEST_TIMEOUT=8           # seconds per curl attempt
FALLBACK_MIRROR="http://archive.ubuntu.com/ubuntu/"
APT_SOURCES_DIR="/etc/apt/sources.list.d"
DEPS=(curl jq shuf awk xargs bc)

# ensure logging folder and files exist
mkdir -p "$(dirname "$LOGFILE")" "$TMPDIR" /etc/cloud
touch "$LOGFILE"

echo "[$(date -u)] Starting OCI region-aware mirror selection" | tee -a "$LOGFILE"

# -----------------------
# Helper: install missing deps if possible
# -----------------------
_missing_deps=()
for cmd in "${DEPS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        _missing_deps+=("$cmd")
    fi
done

if [ ${#_missing_deps[@]} -gt 0 ]; then
    echo "[$(date -u)] Missing dependencies: ${_missing_deps[*]}. Attempting apt-get install (non-interactive)..." | tee -a "$LOGFILE"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >>"$LOGFILE" 2>&1 || true
    apt-get install -y "${_missing_deps[@]}" >>"$LOGFILE" 2>&1 || {
        echo "[$(date -u)] Could not install dependencies automatically. They must be present." | tee -a "$LOGFILE"
        # continue; script will fail later if a required command is missing
    }
fi

# -----------------------
# 1) Determine OCI region (IMDS)
# -----------------------
OCI_REGION="unknown"
if curl -fsS --max-time 2 http://169.254.169.254/opc/v1/instance/region >/dev/null 2>&1; then
    OCI_REGION=$(curl -fsS http://169.254.169.254/opc/v1/instance/region || echo "unknown")
fi
echo "[$(date -u)] OCI region detected: $OCI_REGION" | tee -a "$LOGFILE"
echo "OCI region: $OCI_REGION" > "$INFOFILE"

# -----------------------
# 2) Region -> prioritization keywords
#    (conservative token mapping; not exhaustive)
# -----------------------
get_region_keywords() {
    r="$1"
    r_lc=$(echo "$r" | tr '[:upper:]' '[:lower:]')
    # default: global
    keywords=""

    case "$r_lc" in
        *ash*|*iad*|*phx*|*fra*|*lon*|*lhr*|*man*|*mad*|*ams*|*syd*|*bom*|*hkg*|*gru*|*yyz*|*yul*|*gru*)
            # generic mapping - region codes often include hint substrings
            ;;
    esac

    # heuristics — look for substrings commonly used in OCI region names
    if echo "$r_lc" | grep -q -e "us" -e "ash" -e "iad" -e "phx" -e "lon"; then
        keywords="us us.archive ubuntu.com archive.ubuntu.com mirror us.archive"
    fi
    if echo "$r_lc" | grep -q -e "eu" -e "fra" -e "ams" -e "lon" -e "par" -e "mad"; then
        keywords="de de.archive eu uk fr de.archive.ubuntu.com archive.ubuntu.com"
    fi
    if echo "$r_lc" | grep -q -e "ap" -e "hkg" -e "bom" -e "sin" -e "nrt" -e "tys" -e "phx"; then
        keywords="jp jp.archive in in.archive asia ap archive.ubuntu.com"
    fi
    if echo "$r_lc" | grep -q -e "uk" -e "lon" -e "man"; then
        keywords="uk uk.archive gb archive.ubuntu.com"
    fi
    if [ -z "$keywords" ]; then
        keywords="archive ubuntu mirror"
    fi

    # unique tokens
    echo "$keywords" | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' '
}

PRIORITY_KEYWORDS="$(get_region_keywords "$OCI_REGION")"
echo "[$(date -u)] Priority keywords: $PRIORITY_KEYWORDS" | tee -a "$LOGFILE"

# -----------------------
# 3) Gather mirrors from multiple sources
# -----------------------
echo "[$(date -u)] Gathering mirror candidates..." | tee -a "$LOGFILE"

# a) canonical curated list
if curl -fsS "http://mirrors.ubuntu.com/mirrors.txt" -o "$TMPDIR/mirrors.txt"; then
    # canonical list downloaded
    :
else
    echo "[$(date -u)] Warning: cannot fetch mirrors.ubuntu.com list" | tee -a "$LOGFILE"
fi

# b) Launchpad page (HTML) — extract http(s) urls with ubuntu in host
if curl -fsS "https://launchpad.net/ubuntu/+archivemirrors" -o "$TMPDIR/launchpad.html"; then
    grep -Eo 'https?://[a-zA-Z0-9./-]*ubuntu[^\"]*' "$TMPDIR/launchpad.html" | sed 's/\/$//' | sort -u > "$TMPDIR/launchpad.txt" || true
fi

# c) optional custom list
if [ -f "$CUSTOM_LIST" ]; then
    echo "[$(date -u)] Using custom mirror list: $CUSTOM_LIST" | tee -a "$LOGFILE"
    # sanitize: only keep lines starting with http
    grep -E '^https?://' "$CUSTOM_LIST" | sed 's/\/$//' > "$TMPDIR/custom.txt" || true
fi

# merge them, dedupe
cat "$TMPDIR"/{mirrors.txt,launchpad.txt,custom.txt} 2>/dev/null \
  | sed '/^\s*$/d' \
  | awk '{print tolower($0)}' \
  | sed 's:/$::' \
  | sort -u > "$TMPDIR/all_mirrors.txt" || true

# ensure fallback present
grep -qxF "$FALLBACK_MIRROR" "$TMPDIR/all_mirrors.txt" || echo "$FALLBACK_MIRROR" >> "$TMPDIR/all_mirrors.txt"

TOTAL=$(wc -l < "$TMPDIR/all_mirrors.txt" || echo 0)
echo "[$(date -u)] Collected $TOTAL unique mirrors" | tee -a "$LOGFILE"
echo "[$(date -u)] Sample mirrors (first 20):" | tee -a "$LOGFILE"
head -n 20 "$TMPDIR/all_mirrors.txt" | tee -a "$LOGFILE"

# -----------------------
# 4) Prioritize mirrors matching region keywords
# -----------------------
# function: score mirror by presence of tokens
priority_sort() {
    awk -v kw="$PRIORITY_KEYWORDS" '
    BEGIN {
      nkw=split(kw, a, " ");
      for (i=1;i<=nkw;i++) tok[a[i]]=1;
    }
    {
      score=0; s=$0;
      for (t in tok) {
         if (s ~ t) score+=1;
      }
      print score"\t"$0;
    }' "$1" | sort -k1,1nr -k2,2 | cut -f2- -
}

priority_sort "$TMPDIR/all_mirrors.txt" > "$TMPDIR/prioritized_mirrors.txt"
echo "[$(date -u)] Prioritized mirrors written. Top 20:" | tee -a "$LOGFILE"
head -n 20 "$TMPDIR/prioritized_mirrors.txt" | tee -a "$LOGFILE"

# -----------------------
# 5) Select a manageable test set (top N after prioritization)
# -----------------------
mapfile -t CANDIDATES < <(head -n "$TEST_SAMPLE_COUNT" "$TMPDIR/prioritized_mirrors.txt")
echo "[$(date -u)] Will test ${#CANDIDATES[@]} mirrors (top ${TEST_SAMPLE_COUNT} prioritized)." | tee -a "$LOGFILE"

# -----------------------
# 6) Test mirrors (concurrent) — measure throughput using curl speed_download
#    We'll measure bytes/sec as a float; use tmp file to collect results.
# -----------------------
RESULTS_TMP="$TMPDIR/mirror_results.tsv"
> "$RESULTS_TMP"

test_one() {
    mirror="$1"
    url="${mirror%/}/$TEST_FILE_PATH"

    # reachable? quick HEAD first
    if ! curl -fsS --max-time 3 -I "$mirror/" >/dev/null 2>&1; then
        echo -e "0\tunreachable\t$mirror" >> "$RESULTS_TMP"
        return
    fi

    # measure throughput (bytes/sec) using Release file (small), fallback to HEAD if curl fails
    speed=$(curl -s -L --max-time "$TEST_TIMEOUT" -o /dev/null -w '%{speed_download}' "$url" 2>/dev/null || echo 0)
    # measure total time as additional debug (not used in score now)
    time_total=$(curl -o /dev/null -s -L --max-time "$TEST_TIMEOUT" -w '%{time_total}' "$url" 2>/dev/null || echo 999)

    # write: bytes_per_sec <tab> time_sec <tab> url
    echo -e "${speed}\t${time_total}\t${mirror}" >> "$RESULTS_TMP"
}

export TEST_FILE_PATH TEST_TIMEOUT RESULTS_TMP
export -f test_one

echo "[$(date -u)] Running throughput tests with up to $CONCURRENT_JOBS parallel jobs..." | tee -a "$LOGFILE"
printf "%s\n" "${CANDIDATES[@]}" | xargs -n1 -P"$CONCURRENT_JOBS" -I{} bash -c 'test_one "$@"' _ {}

# Wait briefly to ensure file flush
sleep 1

# -----------------------
# 7) Pick best mirror by throughput (bytes/sec) with tie breaker using time_total
# -----------------------
# Filter out zeros; pick max speed; in case of tie prefer lower time_total
BEST_LINE=$(awk -F'\t' '$1>0{print $0}' "$RESULTS_TMP" | sort -k1,1nr -k2,2n | head -n1 || true)

if [ -z "$BEST_LINE" ]; then
    echo "[$(date -u)] No mirror returned positive throughput. Using fallback $FALLBACK_MIRROR" | tee -a "$LOGFILE"
    BEST_MIRROR="$FALLBACK_MIRROR"
else
    BEST_SPEED_BYTES=$(echo "$BEST_LINE" | awk -F'\t' '{print $1}')
    BEST_MIRROR=$(echo "$BEST_LINE" | awk -F'\t' '{print $3}')
    BEST_TIME=$(echo "$BEST_LINE" | awk -F'\t' '{print $2}')
    echo "[$(date -u)] Best mirror: $BEST_MIRROR (speed_bytes=${BEST_SPEED_BYTES}, time=${BEST_TIME})" | tee -a "$LOGFILE"
fi

# write audit info
{
  echo "OCI region: $OCI_REGION"
  echo "Selected mirror: $BEST_MIRROR"
  echo "Selected speed_bytes: ${BEST_SPEED_BYTES:-0}"
  echo "Tested candidates:"
  sort -k1,1nr "$RESULTS_TMP" 2>/dev/null || true
} >> "$INFOFILE"
chmod 644 "$INFOFILE"

# -----------------------
# 8) Update .sources or /etc/apt/sources.list safely
# -----------------------
echo "[$(date -u)] Updating APT sources to use: $BEST_MIRROR" | tee -a "$LOGFILE"

# prefer the new deb822 .sources file if present
if ls "$APT_SOURCES_DIR"/*.sources >/dev/null 2>&1; then
    for f in "$APT_SOURCES_DIR"/*.sources; do
        if grep -Eq '^URIs:\s*(http|https)://.*' "$f"; then
            # replace URIs: line safely with awk
            awk -v mir="$BEST_MIRROR" 'BEGIN{replaced=0} /^URIs:/ {print "URIs: " mir; replaced=1; next} {print} END{if(!replaced) print "URIs: " mir}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            echo "[$(date -u)] Updated $f" | tee -a "$LOGFILE"
        fi
    done
else
    # fallback to legacy /etc/apt/sources.list replacement
    if [ -f /etc/apt/sources.list ]; then
        sed -n '1,999p' /etc/apt/sources.list > /tmp/sources.list.bak || true
        # careful replacement of archive.ubuntu.com and security.ubuntu.com hosts
        sed -E "s|http(s)?://[a-z0-9.-]*archive.ubuntu.com/ubuntu|${BEST_MIRROR%/}/ubuntu|g" /tmp/sources.list.bak > /etc/apt/sources.list
        echo "[$(date -u)] Updated /etc/apt/sources.list" | tee -a "$LOGFILE"
    fi
fi

# -----------------------
# 9) Refresh apt cache (best-effort, do not fail script if apt fails)
# -----------------------
echo "[$(date -u)] Running apt-get update (best-effort)..." | tee -a "$LOGFILE"
apt-get update -y >>"$LOGFILE" 2>&1 || echo "[$(date -u)] apt-get update returned non-zero; see $LOGFILE" | tee -a "$LOGFILE"

# -----------------------
# 10) Finalize
# -----------------------
echo "[$(date -u)] Mirror selection complete. Best mirror: $BEST_MIRROR" | tee -a "$LOGFILE"
echo "[$(date -u)] Results file: $RESULTS_TMP" | tee -a "$LOGFILE"
echo "[$(date -u)] Cleaning up temp directory $TMPDIR" | tee -a "$LOGFILE"
# keep results file for debugging; do not remove by default
# rm -rf "$TMPDIR"

exit 0
