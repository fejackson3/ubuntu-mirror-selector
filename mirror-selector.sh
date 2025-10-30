#!/bin/bash
# mirror-selector.sh
# OCI / Ubuntu 22.04+ mirror selector
# Fully robust: works with cloud-init, manual runs, and structured .sources files

set -euo pipefail

LOGFILE="/var/log/mirror-selector.log"
INFOFILE="/etc/cloud/mirror-info.txt"

mkdir -p /etc/cloud
echo "[$(date)] Starting mirror selection…" >> "$LOGFILE"

# ---- 1. Check dependencies ----
REQUIRED_CMDS=(curl jq shuf lsb_release awk)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[$(date)] ERROR: required command '$cmd' not found" >> "$LOGFILE"
        exit 1
    fi
done

# ---- 2. Determine Ubuntu codename ----
RELEASE=$(lsb_release -cs)
echo "[$(date)] Ubuntu codename: $RELEASE" >> "$LOGFILE"

# ---- 3. Fetch mirrors ----
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

PRIMARY_URL="http://mirrors.ubuntu.com/mirrors.txt"
FALLBACK_URL="https://mirrors.ubuntu.com/mirrors.txt"
FALLBACK_MIRROR="http://archive.ubuntu.com/ubuntu/"

if ! curl -fsSL "$PRIMARY_URL" -o mirrors.txt; then
    echo "[$(date)] WARNING: HTTP fetch failed, trying HTTPS fallback…" >> "$LOGFILE"
    if ! curl -fsSL "$FALLBACK_URL" -o mirrors.txt; then
        echo "[$(date)] ERROR: Could not fetch mirror list. Using fallback mirror." >> "$LOGFILE"
        echo "$FALLBACK_MIRROR" > mirrors.txt
    fi
fi

# ---- 4. Test mirrors and pick fastest ----
BEST_MIRROR=""
BEST_SPEED=0
TEST_PATH="dists/$RELEASE/Release"

mapfile -t TEST_MIRRORS < <(shuf mirrors.txt | head -n 8)
for M in "${TEST_MIRRORS[@]}"; do
    MS="${M%/}/"  # Ensure trailing slash
    URL="${MS}${TEST_PATH}"
    echo "[$(date)] Testing mirror: $MS" >> "$LOGFILE"
    SPEED=$(curl -o /dev/null -s --max-time 5 -w "%{speed_download}" "$URL" || echo 0)
    SPEED_INT=$(printf "%.0f" "$SPEED")
    echo "[$(date)] Mirror ${MS} speed: ${SPEED_INT} bytes/sec" >> "$LOGFILE"
    if (( SPEED_INT > BEST_SPEED )); then
        BEST_SPEED=$SPEED_INT
        BEST_MIRROR=$MS
    fi
done

# If no mirror succeeded, use fallback
if [[ -z "$BEST_MIRROR" ]]; then
    BEST_MIRROR="$FALLBACK_MIRROR"
    echo "[$(date)] Using fallback mirror: $BEST_MIRROR" >> "$LOGFILE"
else
    echo "[$(date)] Selected fastest mirror: $BEST_MIRROR (speed ${BEST_SPEED} bytes/sec)" >> "$LOGFILE"
fi

# ---- 5. Write audit info ----
echo "Mirror selected: $BEST_MIRROR" > "$INFOFILE"
chmod 644 "$INFOFILE"
echo "[$(date)] Wrote mirror info to $INFOFILE" >> "$LOGFILE"

# ---- 6. Update .sources files safely (Ubuntu 22.04+) ----
for f in /etc/apt/sources.list.d/*.sources; do
    if grep -Eq '^URIs:\s*(http|https)://.*(ubuntu\.com|archive\.ubuntu\.com|security\.ubuntu\.com)' "$f"; then
        # Use awk to safely replace the URIs line
        awk -v mirror="$BEST_MIRROR" '
            /^URIs:/ { print "URIs: " mirror; next }
            { print }
        ' "$f" | sudo tee "${f}.tmp" >/dev/null
        sudo mv "${f}.tmp" "$f"
        echo "[$(date)] Updated $f → ${BEST_MIRROR}" >> "$LOGFILE"
    else
        echo "[$(date)] Skipping $f (no ubuntu.com/ubuntu, archive, or security entries)" >> "$LOGFILE"
    fi
done

# ---- 7. Run apt update ----
sudo apt-get update -y >> "$LOGFILE" 2>&1
echo "[$(date)] Mirror configuration complete." >> "$LOGFILE"
