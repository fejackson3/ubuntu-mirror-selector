#!/bin/bash
# Mirror selector for Ubuntu 22.04+ (OCI-ready)
set -e

LOGFILE="/var/log/mirror-selector.log"
INFOFILE="/etc/cloud/mirror-info.txt"

mkdir -p /etc/cloud
echo "[$(date)] Starting mirror selection…" >> "$LOGFILE"

# Check dependencies
for cmd in curl jq shuf lsb_release; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[$(date)] ERROR: required command '$cmd' not found" >> "$LOGFILE"
        exit 1
    fi
done

RELEASE=$(lsb_release -cs)
echo "[$(date)] Ubuntu codename: $RELEASE" >> "$LOGFILE"

TMPDIR=$(mktemp -d)
cd "$TMPDIR"

# Fetch mirror list via HTTP, fallback HTTPS
MIRROR_LIST_URL="http://mirrors.ubuntu.com/mirrors.txt"
if ! curl -fsSL "$MIRROR_LIST_URL" -o mirrors.txt; then
    echo "[$(date)] WARNING: HTTP fetch failed, trying HTTPS…" >> "$LOGFILE"
    MIRROR_LIST_URL="https://mirrors.ubuntu.com/mirrors.txt"
    curl -fsSL "$MIRROR_LIST_URL" -o mirrors.txt || { echo "[$(date)] ERROR: Could not fetch mirror list." >> "$LOGFILE"; exit 1; }
fi

echo "[$(date)] Fetched mirror list with $(wc -l < mirrors.txt) lines." >> "$LOGFILE"

BEST_MIRROR=""
BEST_SPEED=0
TEST_PATH="dists/$RELEASE/Release"

# Avoid subshell: map mirrors into array
mapfile -t TEST_MIRRORS < <(shuf mirrors.txt | head -n 8)

for M in "${TEST_MIRRORS[@]}"; do
    MS="${M%/}/"
    URL="${MS}${TEST_PATH}"
    echo "[$(date)] Testing mirror: $MS" >> "$LOGFILE"
    SPEED=$(curl -o /dev/null -s --max-time 5 -w "%{speed_download}" "$URL" || echo 0)
    SPEED_INT=$(printf "%.0f" "$SPEED")
    echo "[$(date)] Mirror ${MS} speed: ${SPEED_INT} bytes/sec" >> "$LOGFILE"
    if [ "$SPEED_INT" -gt "$BEST_SPEED" ]; then
        BEST_SPEED=$SPEED_INT
        BEST_MIRROR=$MS
    fi
done

# Fallback if none worked
if [ -z "$BEST_MIRROR" ]; then
    BEST_MIRROR="http://archive.ubuntu.com/ubuntu/"
    echo "[$(date)] No successful mirror test — using fallback $BEST_MIRROR" >> "$LOGFILE"
else
    echo "[$(date)] Selected fastest mirror: $BEST_MIRROR (speed ${BEST_SPEED})" >> "$LOGFILE"
fi

# Write audit info
echo "Mirror selected: $BEST_MIRROR" > "$INFOFILE"
chmod 644 "$INFOFILE"
echo "[$(date)] Wrote mirror info to $INFOFILE" >> "$LOGFILE"

# Update .sources files: match ubuntu.com, archive.ubuntu.com, security.ubuntu.com
for f in /etc/apt/sources.list.d/*.sources; do
    if grep -Eq '^URIs:\s*(http|https)://.*(ubuntu\.com|archive\.ubuntu\.com|security\.ubuntu\.com)' "$f"; then
        sed -i -E "s|^(URIs:\s*)(http|https)://[^ ]*|\\1${BEST_MIRROR}|" "$f"
        echo "[$(date)] Updated $f → ${BEST_MIRROR}" >> "$LOGFILE"
    else
        echo "[$(date)] Skipping $f (no ubuntu.com/ubuntu or archive/security entries)" >> "$LOGFILE"
    fi
done

apt-get update -y >> "$LOGFILE"
echo "[$(date)] Mirror configuration complete." >> "$LOGFILE"
