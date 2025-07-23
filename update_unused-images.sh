#!/bin/bash

# Set up logging with timestamp and daily folder
LOG_DIR="/home/pavdig/logs/docker-update_unused-images_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +'%Y-%m-%d').log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Function for logging with a timestamp
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $@"
}

log "Starting docker-update script."

# List of images to ignore (e.g., "mysql:latest", "redis:alpine")
# Using readonly as this list should not be modified by the script.
readonly IGNORED_IMAGES=(
    "sillytavern:latest"
    "sillytavern:staging"
    "sillytavern"
    "sillytavern-extras"
    "textgen_cpu-only:latest"
    "redis:<none>"
    "tensorchord/pgvecto-rs:<none>"
)

# Convert the ignored images array to a regex pattern for easy matching
# This pattern will be used with grep -E for extended regex matching.
IGNORED_PATTERN=$(IFS="|"; echo "${IGNORED_IMAGES[*]}")

# Get the list of image IDs currently used by any container (running or stopped).
# This is more reliable than matching image names.
log "Finding images used by existing containers (running or stopped)..."
USED_IMAGE_IDS=$(docker ps -a --format '{{.ImageID}}' | sort -u)

log "Scanning all local images to find unused ones to update..."
# Loop over all images, reading ID and name safely.
# This avoids issues with word splitting if image names contain spaces.
docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' | while read -r IMAGE_ID IMAGE_NAME; do
    # Check 1: Is the image in the ignore list?
    if echo "$IMAGE_NAME" | grep -qE "$IGNORED_PATTERN"; then
        log "Skipping ignored image: $IMAGE_NAME"
        continue
    fi

    # Check 2: Is the image actively used by a container?
    # We use `grep -x` for an exact match on the image ID.
    if echo "$USED_IMAGE_IDS" | grep -qx "$IMAGE_ID"; then
        log "Skipping used image: $IMAGE_NAME (ID: $IMAGE_ID)"
        continue
    fi

    # Check 3: Is the image pullable? Images named <none>:<none> cannot be pulled.
    if [[ "$IMAGE_NAME" == "<none>:<none>" ]]; then
        log "Skipping unpullable image: $IMAGE_NAME (ID: $IMAGE_ID)"
        continue
    fi

    # If all checks pass, the image is unused, not ignored, and pullable.
    log "Updating unused image: $IMAGE_NAME"
    docker pull "$IMAGE_NAME"
done

log "Cleaning up old, dangling images."
docker image prune -f
log "Script finished."
echo ""
