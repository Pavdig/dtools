#!/bin/bash

# ==============================================================================
# Advanced Unused Docker Image Updater
#
# Scans for local Docker images that are not in use by any container,
# pulls the latest version, and then prunes any old, dangling images.
#
# Features:
# - Interactive first-run setup with clear explanations.
# - Guides user on setting up user vs. root cron job with permission checks.
# - Interactive selection of images for the ignore list during setup.
# - External configuration file (~/.config/image_updater/config.conf).
# - Dry Run mode to preview actions without making changes (--dry-run).
# ==============================================================================

# --- Strict Mode ---
set -euo pipefail

# --- Cosmetics ---
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NOCOLOR=$'\033[0m'
TICKMARK=$'\033[0;32m\xE2\x9C\x93' # GREEN ✓

# --- User Detection ---
if [[ -n "${SUDO_USER-}" ]]; then
    CURRENT_USER="${SUDO_USER}"
else
    CURRENT_USER="${USER:-$(whoami)}"
fi

# --- Configuration Path ---
CONFIG_DIR="/home/${CURRENT_USER}/.config/image_updater"
CONFIG_FILE="${CONFIG_DIR}/config.conf"

# --- Function to allow interactive image selection ---
interactive_image_selection() {
    SELECTED_IGNORED_IMAGES=() 
    mapfile -t all_images < <(docker images --format '{{.Repository}}:{{.Tag}}' | sort -u)
    if [[ ${#all_images[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No local Docker images found to select from.${NOCOLOR}"; sleep 2; return
    fi
    local selected=()
    for _ in "${all_images[@]}"; do selected+=(0); done
    while true; do
        clear
        echo -e "${YELLOW}Toggle which images to add to the ignore list:${NOCOLOR}\n"
        local i
        for i in "${!all_images[@]}"; do
            if [[ ${selected[$i]} -eq 1 ]]; then
                echo -e "   ${NOCOLOR}[${BLUE}$i${NOCOLOR}] [${TICKMARK}${NOCOLOR}] ${GREEN}${all_images[$i]}${NOCOLOR}"
            else
                echo -e "   ${NOCOLOR}[${BLUE}$i${NOCOLOR}] [${RED}X${NOCOLOR}] ${NOCOLOR}${all_images[$i]}${NOCOLOR}"
            fi
        done
        echo -e "\n${YELLOW}Enter a ${NOCOLOR}[${BLUE}number${NOCOLOR}] ${YELLOW}to toggle selection."
        read -p "Press ENTER when you are finished: " input
        if [[ -z $input ]]; then break; fi
        if [[ $input =~ ^[0-9]+$ ]] && (( input >= 0 && input < ${#all_images[@]} )); then
            selected[$input]=$((1 - selected[$input]))
        else
            echo -e "${RED}Invalid input. Please enter a number from the list.${NOCOLOR}"; sleep 1
        fi
    done
    for i in "${!all_images[@]}"; do
        if [[ ${selected[$i]} -eq 1 ]]; then
            SELECTED_IGNORED_IMAGES+=("${all_images[$i]}")
        fi
    done
}

# --- Function to set up the cron job ---
setup_cron_job() {
    echo ""
    echo -e "${YELLOW}Step 3: Set up a Scheduled Task (Cron Job)${NOCOLOR}"
    read -p "Would you like to schedule this script to run automatically? (Y/n): " schedule_now
    schedule_now=$(echo "${schedule_now:-y}" | tr '[:upper:]' '[:lower:]')

    if [[ "$schedule_now" != "y" && "$schedule_now" != "yes" ]]; then
        echo -e "${YELLOW}Skipping cron job setup. You can run the script manually.${NOCOLOR}"
        return
    fi
    
    local cron_target_user=""
    # Check if the user is in the docker group
    local recommendation_text
    if groups "$CURRENT_USER" | grep -q '\bdocker\b'; then
        recommendation_text="${GREEN}(Recommended)${NOCOLOR}"
    else
        recommendation_text="${YELLOW}(Requires Setup)${NOCOLOR}"
    fi

    clear
    echo -e "${YELLOW}How should the scheduled task be run?${NOCOLOR}"
    echo -e "To interact with Docker, the script needs appropriate permissions."
    echo -e "\n  ${BLUE}1) As your user ('$CURRENT_USER') ${recommendation_text}"
    echo -e "     This is the safest method. It runs with your user's privileges."
    if ! echo "$recommendation_text" | grep -q "Recommended"; then
        echo -e "     ${YELLOW}Prerequisite:${NOCOLOR} Your user must be in the 'docker' group."
        echo -e "     ${YELLOW}To fix, run:${NOCOLOR} ${GREEN}sudo usermod -aG docker $CURRENT_USER${NOCOLOR} (then log out and back in)."
    fi

    echo -e "\n  ${BLUE}2) As the 'root' user (via root's crontab)${NOCOLOR}"
    echo -e "     This method works without any group setup, as 'root' always has permission."
    
    echo -e "\n  ${BLUE}3) Do not schedule${NOCOLOR}"

    read -p "Enter your choice [1-3]: " run_as_choice

    case "$run_as_choice" in
        1) cron_target_user="$CURRENT_USER" ;;
        2) cron_target_user="root" ;;
        3) echo -e "\n${YELLOW}Skipping cron job setup as requested.${NOCOLOR}"; return ;;
        *) echo -e "\n${RED}Invalid choice. Skipping cron job setup.${NOCOLOR}"; return ;;
    esac

    local cron_schedule=""
    local SCRIPT_PATH
    SCRIPT_PATH=$(readlink -f "$0")

    while true; do
        clear
        echo -e "${YELLOW}Please choose a schedule for the image updater (for user: ${GREEN}$cron_target_user${YELLOW}):${NOCOLOR}\n"
        echo "   1) Every 3 hours    5) Every 3 days"
        echo "   2) Every 6 hours    6) Every 7 days (weekly)"
        echo "   3) Every 12 hours   7) Every 14 days"
        echo "   4) Every day        8) Every 30 days"
        echo "   9) Custom           10) Cancel"
        read -p "Enter your choice [1-10]: " choice

        case $choice in
            1) cron_schedule="0 */3 * * *"; break ;;
            2) cron_schedule="0 */6 * * *"; break ;;
            3) cron_schedule="0 */12 * * *"; break ;;
            4) cron_schedule="0 0 * * *"; break ;;
            5) cron_schedule="0 0 */3 * *"; break ;;
            6) cron_schedule="0 0 * * 0"; break ;;
            7) cron_schedule="0 0 */14 * *"; break ;;
            8) cron_schedule="0 0 */30 * *"; break ;;
            9) read -p "Enter custom cron schedule expression: " custom_cron
               if [[ -n "$custom_cron" ]]; then cron_schedule="$custom_cron"; break; fi ;;
            10) cron_schedule=""; break ;;
            *) echo -e "${RED}Invalid option. Please try again.${NOCOLOR}"; sleep 1 ;;
        esac
    done

    if [[ -z "$cron_schedule" ]]; then
        echo -e "\n${YELLOW}Cron job setup canceled.${NOCOLOR}"
        return
    fi

    echo -e "\n${YELLOW}Adding job to crontab for user '${GREEN}$cron_target_user${YELLOW}'...${NOCOLOR}"

    local cron_command="$cron_schedule $SCRIPT_PATH"
    local cron_comment="# Added by image-updater script to run automatically"

    local current_crontab
    # Get crontab content. For root, we don't need 'sudo -u'.
    if [[ "$cron_target_user" == "root" ]]; then
        current_crontab=$(crontab -l 2>/dev/null || true)
    else
        current_crontab=$(sudo -u "$cron_target_user" crontab -l 2>/dev/null || true)
    fi

    if echo "$current_crontab" | grep -Fq "$SCRIPT_PATH"; then
        echo -e "${YELLOW}A cron job for this script already exists for this user. Skipping.${NOCOLOR}"
    else
        # Pipe the new content to the appropriate user's crontab
        if [[ "$cron_target_user" == "root" ]]; then
            (printf "%s\n" "$current_crontab"; printf "%s\n" "$cron_comment"; printf "%s\n" "$cron_command") | crontab -
        else
            (printf "%s\n" "$current_crontab"; printf "%s\n" "$cron_comment"; printf "%s\n" "$cron_command") | sudo -u "$cron_target_user" crontab -
        fi
        echo -e "${GREEN}${TICKMARK} Cron job added successfully!${NOCOLOR}"
    fi
}


# --- Function for First-Time Setup ---
initial_setup() {
    clear
    echo -e "${BLUE}#########################################################${NOCOLOR}"
    echo -e "${BLUE}#   ${YELLOW}Welcome to the unused Docker Image Updater Setup!   ${BLUE}#${NOCOLOR}"
    echo -e "${BLUE}#########################################################${NOCOLOR}\n"
    echo -e "This setup will configure the script and save settings to: ${GREEN}${CONFIG_FILE}${NOCOLOR}\n"

    # --- Step 1: Log Directory ---
    local log_dir_def="/home/${CURRENT_USER}/logs/image_updater_logs"
    echo -e "${YELLOW}Step 1: Set Log Directory Path${NOCOLOR}"
    read -p "Enter path [${GREEN}${log_dir_def}${NOCOLOR}]: " LOG_DIR
    LOG_DIR=${LOG_DIR:-$log_dir_def}
    echo ""

    # --- Step 2: Interactive Ignore List ---
    declare -a SELECTED_IGNORED_IMAGES=()
    echo -e "${YELLOW}Step 2: Configure Ignore List${NOCOLOR}"
    read -p "Do you want to interactively select images to ignore now? (y/N): " select_now
    if [[ "$(echo "${select_now:-n}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|yes)$ ]]; then
        interactive_image_selection
    fi
    
    # --- Confirmation before writing files ---
    clear
    echo -e "\n${GREEN}_--| Image Updater Setup |---_${NOCOLOR}\n"
    echo -e "${YELLOW}--- Configuration Summary ---${NOCOLOR}"
    echo -e "Please review the settings before saving:\n"
    echo -e "  ${BLUE}Log Directory:${NOCOLOR}  ${GREEN}${LOG_DIR}${NOCOLOR}"
    if [[ ${#SELECTED_IGNORED_IMAGES[@]} -gt 0 ]]; then
        echo -e "  ${BLUE}Images to Ignore:${NOCOLOR}"
        for image in "${SELECTED_IGNORED_IMAGES[@]}"; do echo -e "    - ${GREEN}$image${NOCOLOR}"; done
    else
        echo -e "  ${BLUE}Images to Ignore:${NOCOLOR} ${YELLOW}None selected. Default examples will be added.${NOCOLOR}"
    fi
    echo ""
    read -p "Save this configuration and proceed? (Y/n): " confirm_setup
    
    if [[ ! "$(echo "${confirm_setup:-y}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|yes)$ ]]; then
        echo -e "\n${RED}Setup canceled.${NOCOLOR}"; exit 1
    fi

    # --- Write Config File ---
    echo -e "\n${GREEN}Saving configuration...${NOCOLOR}"
    mkdir -p "${CONFIG_DIR}"
    local ignored_images_string=""
    if [[ ${#SELECTED_IGNORED_IMAGES[@]} -gt 0 ]]; then
        for image in "${SELECTED_IGNORED_IMAGES[@]}"; do
            ignored_images_string+="    \"${image}\""$'\n'
        done
        ignored_images_string=${ignored_images_string%$'\n'}
    else
        ignored_images_string=$(cat <<'EOD'
    "example-unused-image:latest"
    "example-unused-image-2:<none>"
EOD
)
    fi
    tee "${CONFIG_FILE}" > /dev/null << EOF
# --- User Configuration for Unused Image Updater ---
LOG_DIR="${LOG_DIR}"
IGNORED_IMAGES=(
${ignored_images_string}
)
EOF

    # --- Set Permissions ---
    echo -e "${YELLOW}Setting permissions...${NOCOLOR}"
    chown -R "${CURRENT_USER}:${CURRENT_USER}" "${CONFIG_DIR}"
    mkdir -p "${LOG_DIR}"
    chown -R "${CURRENT_USER}:${CURRENT_USER}" "${LOG_DIR}"
    
    # --- Final Step: Cron Job ---
    setup_cron_job

    echo -e "\n${GREEN}${TICKMARK} Setup complete! The script will now continue.${NOCOLOR}\n"
    sleep 2
}


# --- Main Script Logic ---

if [[ ! -f "${CONFIG_FILE}" ]]; then
    if [[ $EUID -eq 0 ]]; then initial_setup; else
       echo -e "${RED}This script's initial setup must be run with 'sudo'.${NOCOLOR}"; exit 1
    fi
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +'%Y-%m-%d').log"

log() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $@"
    echo "$message"; echo "$message" >> "$LOG_FILE"
}

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then DRY_RUN=true; fi

log "Starting image-update script."
if $DRY_RUN; then log "--- Starting in Dry Run mode. No changes will be made. ---"; fi

if [[ ${#IGNORED_IMAGES[@]} -eq 0 ]]; then IGNORED_PATTERN="^$"; else
    IGNORED_PATTERN=$(IFS="|"; echo "${IGNORED_IMAGES[*]}")
fi

total_images_scanned=0; used_count=0; ignored_count=0; unpullable_count=0

log "Finding images used by existing containers (running or stopped)..."
get_used_image_ids() {
    local container_ids; container_ids=$(docker ps -aq)
    if [ -z "$container_ids" ]; then return; fi
    for id in $container_ids; do
        docker inspect --format='{{.Image}}' "$id" | sed 's/sha256://' | cut -c1-12
    done | sort -u
}
USED_IMAGE_IDS=$(get_used_image_ids)

declare -a images_to_update=()
log "Scanning all local images to find unused ones to update..."
while read -r IMAGE_ID IMAGE_NAME; do
    total_images_scanned=$((total_images_scanned + 1))
    if echo "$USED_IMAGE_IDS" | grep -qx "$IMAGE_ID"; then
        log "Skipping used image: $IMAGE_NAME (ID: $IMAGE_ID)"; used_count=$((used_count + 1)); continue
    fi
    if [[ ${#IGNORED_IMAGES[@]} -gt 0 ]] && echo "$IMAGE_NAME" | grep -qE "$IGNORED_PATTERN"; then
        log "Skipping ignored image: $IMAGE_NAME"; ignored_count=$((ignored_count + 1)); continue
    fi
    if [[ "$IMAGE_NAME" == "<none>:<none>" ]]; then
        log "Skipping unpullable image: $IMAGE_NAME (ID: $IMAGE_ID)"; unpullable_count=$((unpullable_count + 1)); continue
    fi
    images_to_update+=("$IMAGE_NAME")
done < <(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}')

if [ ${#images_to_update[@]} -gt 0 ]; then
    log "Found ${#images_to_update[@]} images to update. Starting parallel pulls..."
    for image in "${images_to_update[@]}"; do
        (
            if $DRY_RUN; then log "[Dry Run] Would update image: $image"
            else
                log "Updating unused image: $image"
                docker pull "$image" >> "$LOG_FILE" 2>&1
            fi
        ) &
    done
    wait
    log "All image updates are complete."
else
    log "No unused images found to update."
fi

updated_count=${#images_to_update[@]}
if ! $DRY_RUN; then
    log "Cleaning up old, dangling images..."
    prune_output=$(docker image prune -f); log "$prune_output"
else
    log "[Dry Run] Would run 'docker image prune -f'."
fi

log "--- Update Summary ---"
log "Total images scanned: $total_images_scanned"
if $DRY_RUN; then log "Images that would be updated: $updated_count"; else
    log "Images updated: $updated_count"; fi
log "Images skipped (in use): $used_count"
log "Images skipped (on ignore list): $ignored_count"
log "Images skipped (un-pullable): $unpullable_count"
log "Script finished."
echo ""
