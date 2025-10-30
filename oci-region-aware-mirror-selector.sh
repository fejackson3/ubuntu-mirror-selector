#!/bin/bash
# OCI Region-Aware Ubuntu Mirror Selector with Reachability Check
# Works on Ubuntu 22.04 and 24.04 across all OCI regions globally

set -euo pipefail

log() { echo "[$(date -u +'%a %b %d %H:%M:%S UTC %Y')] $*"; }

TMPDIR=$(mktemp -d /tmp/oci-mirror-XXXX)
RESULTS_FILE="$TMPDIR/mirror_results.tsv"
INFO_FILE="/etc/cloud/mirror-info.txt"
MAX_TESTS=12
MAX_PARALLEL=6
CURL_OPTS="-L --silent --show-error --max-time 3 --connect-timeout 2"

log "Starting OCI region-aware mirror selection"

# Detect OCI region from metadata
OCI_REGION=$(curl -s http://169.254.169.254/opc/v1/instance/ | grep -o '"region":"[^"]*' | cut -d'"' -f4 || echo "unknown")
log "OCI region detected: $OCI_REGION"

# Set region keywords to prioritize likely mirrors
case "$OCI_REGION" in
  *tokyo*|*osaka*|*seoul*|*singapore*|*mumbai*|*sydney*)
    PRIORITY_KEYWORDS="jp kr sg in au asia ap archive.ubuntu.com"
    ;;
  *frankfurt*|*zurich*|*stockholm*|*paris*|*amsterdam*|*london*)
    PRIORITY_KEYWORDS="de fr se nl uk eu archive.ubuntu.com"
    ;;
  *ashburn*|*phoenix*|*chicago*|*montreal*|*toronto*)
    PRIORITY_KEYWORDS="us ca na archive.ubuntu.com"
    ;;
  *saopaulo*|*mexico*|*santiago*)
    PRIORITY_KEYWORDS="br mx cl sa la archive.ubuntu.com"
    ;;
  *)
    PRIORITY_KEYWORDS="archive.ubuntu.com"
    ;;
esac
log "Priority keywords: $PRIORITY_KEYWORDS"

# --- Gather mirrors from Launchpad and mirrors.ubuntu.com ---
log "Gathering mirror candidates..."
{
  curl -fsSL https://launchpad.net/ubuntu/+archivemirrors || true
  curl -fsSL https://mirrors.ubuntu.com/mirrors.txt || true
} > "$TMPDIR/all_mirrors_raw.txt"

# Extract and sanitize URLs
grep -Eo '(http|https)://[^"'"'"'<> ]+' "$TMPDIR/all_mirrors_raw.txt" \
  | grep ubuntu \
  | grep -vE 'launchpad.net|askubuntu.com|ppa.launchpad.net' \
  | sed 's|/$||' \
  | sort -u > "$TMPDIR/all_mirrors.txt"

TOTAL=$(wc -l < "$TMPDIR/all_mirrors.txt")
log "Collected $TOTAL unique mirrors"

# --- Prioritize by region keywords ---
grep -iE "$(echo $PRIORITY_KEYWORDS | sed 's/ /|/g')" "$TMPDIR/all_mirrors.txt" > "$TMPDIR/prioritized.txt" || true
cat "$TMPDIR/all_mirrors.txt" >> "$TMPDIR/prioritized.txt"
sort -u "$TMPDIR/prioritized.txt" | head -n 100 > "$TMPDIR/mirrors_top.txt"

log "Prioritized mirrors written. Testing reachability..."

# --- Reachability check ---
REACHABLE_FILE="$TMPDIR/reachable.txt"
touch "$REACHABLE_FILE"

xargs -I{} -P "$MAX_PARALLEL" bash -c '
  url="{}"
  if curl --head --silent --max-time 3 --connect-timeout 2 "$url/dists/stable/Release" >/dev/null 2>&1 ||
     curl --head --silent --max-time 3 --connect-timeout 2 "$url/dists/noble/Release" >/dev/null 2>&1; then
    echo "$url" >> "'"$REACHABLE_FILE"'"
  fi
' < "$TMPDIR/mirrors_top.txt"

REACHABLE_COUNT=$(wc -l < "$REACHABLE_FILE")
log "Reachable mirrors: $REACHABLE_COUNT"

if [[ $REACHABLE_COUNT -lt 2 ]]; then
  log "Too few reachable mirrors. Falling back to archive.ubuntu.com"
  echo "http://archive.ubuntu.com/ubuntu" > "$REACHABLE_FILE"
fi

# --- Throughput tests ---
TEST_MIRRORS=$(head -n "$MAX_TESTS" "$REACHABLE_FILE")
log "Testing up to $MAX_TESTS mirrors for bandwidth..."

echo "$TEST_MIRRORS" | xargs -I{} -P "$MAX_PARALLEL" bash -c '
  url="{}"
  start=$(date +%s.%N)
  bytes=$(curl -w "%{size_download}" -o /dev/null '"$CURL_OPTS"' "$url/dists/stable/Release" 2>/dev/null || echo 0)
  end=$(date +%s.%N)
  elapsed=$(echo "$end - $start" | bc)
  echo -e "${bytes}\t${elapsed}\t${url}"
' | sort -nr -k1 > "$RESULTS_FILE"

BEST_MIRROR=$(head -n1 "$RESULTS_FILE" | awk '{print $3}')
BEST_SPEED=$(head -n1 "$RESULTS_FILE" | awk '{print $1}')

log "Best mirror: $BEST_MIRROR (speed_bytes=$BEST_SPEED)"

# --- Update APT sources ---
if [[ -n "$BEST_MIRROR" ]]; then
  sudo sed -i "s|URIs:.*|URIs: $BEST_MIRROR|" /etc/apt/sources.list.d/ubuntu.sources || true
  log "Updated /etc/apt/sources.list.d/ubuntu.sources"
fi

# --- Save results ---
{
  echo "OCI region: $OCI_REGION"
  echo "Selected mirror: $BEST_MIRROR"
  echo "Selected speed_bytes: $BEST_SPEED"
  echo "Tested candidates:"
  cat "$RESULTS_FILE"
} | tee "$INFO_FILE"

log "Mirror selection complete. Best mirror: $BEST_MIRROR"
log "Results file: $RESULTS_FILE"
log "Cleaning up temp directory $TMPDIR"
rm -rf "$TMPDIR"
