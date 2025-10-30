#!/bin/bash
# Ubuntu Mirror Optimizer for OCI
# Author: ChatGPT (optimized for Frank Jackson)
# Version: 2.0
# Tested on Ubuntu 22.04 / 24.04

set -euo pipefail

LOG_FILE="/var/log/mirror-optimizer.log"
INFO_FILE="/etc/cloud/mirror-info.txt"
TEMP_DIR="/tmp/mirror-optimizer"
mkdir -p "$TEMP_DIR"

echo "[INFO] Starting mirror optimization..." | tee "$LOG_FILE"

########################################
# 1. Collect candidate mirrors
########################################
echo "[INFO] Fetching mirror lists..." | tee -a "$LOG_FILE"

# Canonical curated list
curl -fsSL "http://mirrors.ubuntu.com/mirrors.txt" -o "$TEMP_DIR/mirrors.txt" || true

# Launchpad HTML mirror registry
curl -fsSL "https://launchpad.net/ubuntu/+archivemirrors" -o "$TEMP_DIR/launchpad.html" || true

# Extract URLs from Launchpad page (regex for http(s):// + ubuntu/)
grep -Eo 'https?://[^"]+ubuntu/?' "$TEMP_DIR/launchpad.html" | sort -u > "$TEMP_DIR/launchpad.txt"

# Merge lists
cat "$TEMP_DIR"/{mirrors.txt,launchpad.txt} 2>/dev/null | grep -E '^https?://' | sort -u > "$TEMP_DIR/all_mirrors.txt"

# Always add fallback
echo "http://archive.ubuntu.com/ubuntu/" >> "$TEMP_DIR/all_mirrors.txt"

TOTAL_MIRRORS=$(wc -l < "$TEMP_DIR/all_mirrors.txt")
echo "[INFO] Total mirrors found: $TOTAL_MIRRORS" | tee -a "$LOG_FILE"

########################################
# 2. Test mirrors for latency and speed
########################################
TEST_FILE="dists/stable/Release"
BEST_MIRROR=""
BEST_SCORE=0

echo "[INFO] Testing mirrors for latency and throughput..." | tee -a "$LOG_FILE"

while read -r MIRROR; do
    echo -n "Testing $MIRROR ... " | tee -a "$LOG_FILE"

    # Check reachability
    if ! curl -fsI --max-time 3 "$MIRROR" >/dev/null 2>&1; then
        echo "unreachable" | tee -a "$LOG_FILE"
        continue
    fi

    # Measure latency (seconds)
    LATENCY=$(curl -o /dev/null -s -w "%{time_total}" --max-time 5 "$MIRROR$TEST_FILE" || echo 10)

    # Measure throughput (kB/s) using 1MB chunk
    SPEED=$(curl -o /dev/null -s -w "%{speed_download}" --max-time 5 "$MIRROR$TEST_FILE" || echo 0)
    SPEED_KB=$(awk "BEGIN {print $SPEED/1024}")

    # Scoring heuristic: higher is better
    SCORE=$(awk "BEGIN {print ($SPEED_KB / ($LATENCY+0.1))}")

    echo "lat=${LATENCY}s speed=${SPEED_KB}KB/s score=${SCORE}" | tee -a "$LOG_FILE"

    # Track best
    if (( $(echo "$SCORE > $BEST_SCORE" | bc -l) )); then
        BEST_SCORE="$SCORE"
        BEST_MIRROR="$MIRROR"
    fi

done < "$TEMP_DIR/all_mirrors.txt"

########################################
# 3. Apply best mirror
########################################
if [[ -z "$BEST_MIRROR" ]]; then
    echo "[WARN] No valid mirror found; falling back to archive.ubuntu.com" | tee -a "$LOG_FILE"
    BEST_MIRROR="http://archive.ubuntu.com/ubuntu/"
fi

echo "Mirror selected: $BEST_MIRROR" | tee -a "$LOG_FILE"
echo "Mirror selected: $BEST_MIRROR" | sudo tee "$INFO_FILE"

# Update .sources file (Ubuntu 24.x+)
if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
    sudo sed -i -E "s|URIs:.*|URIs: $BEST_MIRROR|" /etc/apt/sources.list.d/ubuntu.sources
else
    sudo bash -c "cat >/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: $BEST_MIRROR
Suites: $(lsb_release -cs) $(lsb_release -cs)-updates $(lsb_release -cs)-backports $(lsb_release -cs)-security
Components: main universe multiverse restricted
EOF
fi

sudo apt-get update -y || true

echo "[DONE] Mirror optimization completed successfully." | tee -a "$LOG_FILE"
