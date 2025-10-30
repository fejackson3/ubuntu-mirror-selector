#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "[$(date)] Starting OCI region-aware mirror selection"

TMPDIR=$(mktemp -d /tmp/oci-mirror-XXXX)
RESULTS="$TMPDIR/mirror_results.tsv"

# Optionally allow custom mirrors
CUSTOM_MIRRORS_FILE=${CUSTOM_MIRRORS_FILE:-""}

# OCI region detection (best-effort)
OCI_REGION=$(curl -fsSL -m 2 http://169.254.169.254/opc/v1/instance/region || echo "unknown")
echo "[$(date)] OCI region detected: $OCI_REGION"

# Gather mirrors from Launchpad
echo "[$(date)] Gathering mirror candidates from Launchpad..."
LAUNCHPAD_MIRRORS=($(curl -fsSL https://launchpad.net/ubuntu/+archivemirrors | \
                     grep -oP 'http[s]?://[^\s"]+/ubuntu' | sort -u))

# Include archive.ubuntu.com fallback
ARCHIVE_MIRRORS=(
    http://archive.ubuntu.com/ubuntu/
)

# Include custom mirrors if provided
CUSTOM_MIRRORS=()
if [[ -f "$CUSTOM_MIRRORS_FILE" ]]; then
    CUSTOM_MIRRORS=($(grep -v '^#' "$CUSTOM_MIRRORS_FILE" | grep -v '^$'))
fi

# Combine all mirrors
CANDIDATES=( "${CUSTOM_MIRRORS[@]}" "${LAUNCHPAD_MIRRORS[@]}" "${ARCHIVE_MIRRORS[@]}" )

# Filter reachable mirrors
echo "[$(date)] Checking mirror reachability..."
REACHABLE=()
for mirror in "${CANDIDATES[@]}"; do
    if curl --head --max-time 5 -fsSL "$mirror" &>/dev/null; then
        REACHABLE+=("$mirror")
    fi
done
echo "[$(date)] ${#REACHABLE[@]} reachable mirrors found."

# Limit test to top 12 mirrors for speed
TEST_MIRRORS=("${REACHABLE[@]:0:12}")

# Measure throughput
echo "[$(date)] Running throughput tests..."
> "$RESULTS"
for mirror in "${TEST_MIRRORS[@]}"; do
    {
        SPEED=$(curl -s -w '%{speed_download} %{time_total}\n' -o /dev/null "$mirror/README")
        echo -e "$SPEED\t$mirror" >> "$RESULTS"
    } &
done
wait

# Select best mirror
BEST_MIRROR=$(sort -nrk1 "$RESULTS" | head -n1 | awk '{print $3}')
BEST_SPEED=$(sort -nrk1 "$RESULTS" | head -n1 | awk '{print $1}')
echo "[$(date)] Best mirror: $BEST_MIRROR (speed_bytes=$BEST_SPEED)"

# Update APT sources
echo "[$(date)] Updating APT sources..."
cat <<EOF | sudo tee /etc/apt/sources.list.d/ubuntu.sources
## URIs: A URL to the repository (you may add multiple URLs)
URIs: $BEST_MIRROR
URIs: $BEST_MIRROR
EOF

echo "[$(date)] Mirror selection complete. Results stored in $RESULTS"
echo "OCI region: $OCI_REGION" | sudo tee /etc/cloud/mirror-info.txt
echo "Selected mirror: $BEST_MIRROR" | sudo tee -a /etc/cloud/mirror-info.txt
echo "Selected speed_bytes: $BEST_SPEED" | sudo tee -a /etc/cloud/mirror-info.txt
echo "Tested candidates:" | sudo tee -a /etc/cloud/mirror-info.txt
sort -nrk1 "$RESULTS" | sudo tee -a /etc/cloud/mirror-info.txt

# Optional: run apt-get update
sudo apt-get update -y || true

# Cleanup
rm -rf "$TMPDIR"
