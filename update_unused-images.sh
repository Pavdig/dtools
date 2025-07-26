#!/bin/bash

# ==============================================================================
# Advanced Unused Docker Image Updater
#
# Scans for local Docker images that are not in use by any container,
# pulls the latest version, and then prunes any old, dangling images.
#
# Features:
# - External configuration for ignored images.
# - Dry Run mode to preview actions without making changes (--dry-run).
# - Parallel image pulls for faster execution.
# - Detailed logging and a final summary report.
# ==============================================================================

# --- Strict Mode ---
set -euo pipefail

# --- Default Configuration (overridden by external config) ---
CONFIG_DIR="$HOME/.config/image_updater"
CONFIG_FILE="$CONFIG_DIR/config.sh"
LOG_DIR="/home/pavdig/logs/update_unused-images_logs"
IGNORED_IMAGES=() # Default empty array

# --- Function to create and source the external configuration ---
setup_and_load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file not found. Creating a default one at '$CONFIG_FILE'..."
        mkdir -p "$CONFIG_DIR"
        cat > "$CONFIG_FILE" << EOL
#!/bin/bash
# --- User Configuration for Unused Image Updater ---

# Directory for log files.
LOG_DIR="/home/pavdig/logs/update_unused-images_logs"

# List of images to ignore during the update process.
# Use the format "repository:tag" or just "repository" to ignore all tags.
IGNORED_IMAGES=(
    "sillytavern:latest"
    "sillytavern:staging"
    "sillytavern"
    "sillytavern-extras"
    "textgen_cpu-only:latest"
    "redis:<none>"
    "tensorchord/pgvecto-rs:<none>"
)
EOL
        echo "Default config created. Please review it and re-run the script."
        sleep 2
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

# --- Main Script Logic ---

# Load config first to get correct LOG_DIR
setup_and_load_config

# --- Logging Setup ---
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +'%Y-%m-%d').log"

# *** FIX: Use a log function that explicitly writes to console and file, instead of global exec ***
log() {
    local message
    message="[$(date +'%Y-%m-%d %H:%M:%S')] $@"
    echo "$message" # Print to console
    echo "$message" >> "$LOG_FILE" # Append to log file
}

# --- Script Initialization ---
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
    DRY_RUN=true
fi

log "Starting image-update script."
if $DRY_RUN; then
    log "--- Starting in Dry Run mode. No changes will be made. ---"
fi

IGNORED_PATTERN=$(IFS="|"; echo "${IGNORED_IMAGES[*]}")

# --- Counters for Summary Report ---
total_images_scanned=0
used_count=0
ignored_count=0
unpullable_count=0

# --- Phase 1: Discover Images to Update ---
log "Finding images used by existing containers (running or stopped)..."

get_used_image_ids() {
    local container_ids
    container_ids=$(docker ps -aq)
    if [ -z "$container_ids" ]; then
        return
    fi
    for id in $container_ids; do
        local image_sha
        image_sha=$(docker inspect --format='{{.Image}}' "$id")
        local image_hash=${image_sha#sha256:}
        echo "${image_hash:0:12}"
    done | sort -u
}

USED_IMAGE_IDS=$(get_used_image_ids)

declare -a images_to_update=()
log "Scanning all local images to find unused ones to update..."

while read -r IMAGE_ID IMAGE_NAME; do
    total_images_scanned=$((total_images_scanned + 1))
    
    if echo "$USED_IMAGE_IDS" | grep -qx "$IMAGE_ID"; then
        log "Skipping used image: $IMAGE_NAME (ID: $IMAGE_ID)"
        used_count=$((used_count + 1))
        continue
    fi

    if echo "$IMAGE_NAME" | grep -qE "$IGNORED_PATTERN"; then
        log "Skipping ignored image: $IMAGE_NAME"
        ignored_count=$((ignored_count + 1))
        continue
    fi

    if [[ "$IMAGE_NAME" == "<none>:<none>" ]]; then
        log "Skipping unpullable image: $IMAGE_NAME (ID: $IMAGE_ID)"
        unpullable_count=$((unpullable_count + 1))
        continue
    fi

    images_to_update+=("$IMAGE_NAME")
done < <(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}')

# --- Phase 2: Perform Updates in Parallel ---
if [ ${#images_to_update[@]} -gt 0 ]; then
    log "Found ${#images_to_update[@]} images to update. Starting parallel pulls..."
    for image in "${images_to_update[@]}"; do
        (
            if $DRY_RUN; then
                # In dry run, we still log to the main file
                log "[Dry Run] Would update image: $image"
            else
                log "Updating unused image: $image"
                # Redirect output of the pull command to the main log file
                docker pull "$image" >> "$LOG_FILE" 2>&1
            fi
        ) &
    done
    wait
    log "All image updates are complete."
else
    log "No unused images found to update."
fi

# --- Phase 3: Cleanup and Summary ---
updated_count=${#images_to_update[@]}

if ! $DRY_RUN; then
    log "Cleaning up old, dangling images..."
    # Capture prune output and log it
    prune_output=$(docker image prune -f)
    log "$prune_output"
else
    log "[Dry Run] Would run 'docker image prune -f'."
fi

log "--- Update Summary ---"
log "Total images scanned: $total_images_scanned"
if $DRY_RUN; then
    log "Images that would be updated: $updated_count"
else
    log "Images updated: $updated_count"
fi
log "Images skipped (in use): $used_count"
log "Images skipped (on ignore list): $ignored_count"
log "Images skipped (un-pullable): $unpullable_count"
log "Script finished."
echo ""
