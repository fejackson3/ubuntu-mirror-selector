#!/bin/bash
# mirror-selector.sh
# Detects fastest Ubuntu mirror, updates /etc/apt/sources.list.d/*.sources, logs results.
# Optional custom mirrors list: /etc/cloud/custom-mirrors.txt

set -euo pipefail

LOGFILE="/var/log/mirror-selector.log"
INFOFILE="/etc/cloud/mirror-info.txt"
mkdir -p /etc/cloud

echo "[$(date)] Starting mirror selection…" | tee -a "$LOGFILE"

# Check dependencies
for cmd in curl jq shuf lsb_release bc; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "[$(date)] ERROR: required command '$cmd' not found" | tee -a "$LOGFILE"
        exit 1
    fi
done

# Determine Ubuntu release codename
RELEASE=$(lsb_release -cs)
echo "[$(date)] Ubuntu codename: $RELEASE" | tee -a "$LOGFILE"

# Detect OCI region
OCI_REGION=$(curl -fsSL http://169.254.169.254/opc/v1/instance/region || echo "unknown")
echo "[$(date)] OCI region: $OCI_REGION" | tee -a "$LOGFILE"
echo "OCI region: $OCI_REGION" > "$INFOFILE"

TMPDIR=$(mktemp -d)
cd "$TMPDIR"

# Load mirrors: custom file overrides default
CUSTOM_LIST_FILE="/etc/cloud/custom-mirrors.txt"
if [ -f "$CUSTOM_LIST_FILE" ]; then
    echo "[$(date)] Using custom mirrors from $CUSTOM_LIST_FILE" | tee -a "$LOGFILE"
    MIRRORS=$(cat "$CUSTOM_LIST_FILE")
else
    echo "[$(date)] Fetching default mirrors list from http://mirrors.ubuntu.com/mirrors.txt" | tee -a "$LOGFILE"
    MIRRORS=$(curl -fsSL http://mirrors.ubuntu.com/mirrors.txt || echo "http://archive.ubuntu.com/ubuntu/")
fi

echo "[$(date)] Mirrors to test:" | tee -a "$LOGFILE"
echo "$MIRRORS" | tee -a "$LOGFILE"

BEST_MIRROR=""
BEST_SPEED=0
TEST_PATH="dists/$RELEASE/Release"

# Test each mirror (shuffle and take first 10 for speed)
echo "$MIRRORS" | shuf | head -n 10 | while read -r M; do
    MS="${M%/}/"  # Ensure trailing slash
    URL="${MS}${TEST_PATH}"
    echo "[$(date)] Testing mirror: $MS" | tee -a "$LOGFILE"
    SPEED=$(curl -o /dev/null -s --max-time 5 -w "%{speed_download}" "$URL" || echo 0)
    echo "Mirror $MS speed: $SPEED bytes/sec" | tee -a "$LOGFILE"
    if (( $(echo "$SPEED > $BEST_SPEED" | bc -l) )); then
        BEST_SPEED=$SPEED
        BEST_MIRROR=$MS
    fi
done

# Fallback if no mirror succeeded
if [ -z "$BEST_MIRROR" ]; then
    BEST_MIRROR="http://archive.ubuntu.com/ubuntu/"
    echo "[$(date)] No successful mirror test — using fallback $BEST_MIRROR" | tee -a "$LOGFILE"
else
    echo "[$(date)] Selected fastest mirror: $BEST_MIRROR (speed ${BEST_SPEED} bytes/sec)" | tee -a "$LOGFILE"
fi

# Write selected mirror to info file
echo "Mirror selected: $BEST_MIRROR" >> "$INFOFILE"

# Update .sources files (Ubuntu 22.04+)
for f in /etc/apt/sources.list.d/*.sources; do
    if grep -Eq '^URIs:\s*(http|https)://[^ ]*ubuntu\.com/ubuntu/' "$f"; then
        sed -i -E "s|^(URIs:\s*)(http|https)://[^ ]*ubuntu\.com/ubuntu/|\1${BEST_MIRROR}|" "$f"
        echo "[$(date)] Updated $f → ${BEST_MIRROR}" | tee -a "$LOGFILE"
    else
        echo "[$(date)] Skipping $f (no ubuntu.com/ubuntu entry found)" | tee -a "$LOGFILE"
    fi
done

# Apply new mirrors
apt-get update -y | tee -a "$LOGFILE"
echo "[$(date)] Mirror configuration complete." | tee -a "$LOGFILE"
