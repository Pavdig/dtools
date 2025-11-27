#!/bin/bash
# ======================================================================================
# --- Docker Tool Suite ---
# ======================================================================================

SCRIPT_VERSION=v1.4.4

# --- Strict Mode & Globals ---
set -euo pipefail
DRY_RUN=false
IS_CRON_RUN=false

# ======================================================================================
# --- SECTION 1: SHARED FUNCTIONS & CONFIGURATION ---
# ======================================================================================

# --- Cosmetics ---
C_RED=$'\e[31m'
C_BOLD_RED=$'\e[1;31m'
C_GREEN=$'\e[32m'
C_YELLOW=$'\e[33m'
C_BLUE=$'\e[34m'
C_GRAY=$'\e[90m'
C_RESET=$'\e[0m'
TICKMARK=$'\e[32m\xE2\x9C\x93' # GREEN ✓

# --- Standardized Footer Options ---
optionsRandQ=( # Options to Return and Quit
        "${C_GRAY}(R)eturn to previous menu${C_RESET}"
        "${C_RED}(Q)uit the tool${C_RESET}"
)

optionsOnlyQ=( # Option for Main Menu (Quit only)
        "${C_RED}(Q)uit the tool${C_RESET}"
)

# --- User & Path Detection ---
if [[ -n "${SUDO_USER-}" ]]; then
    CURRENT_USER="${SUDO_USER}"
else
    CURRENT_USER="${USER:-$(whoami)}"
fi
SCRIPT_PATH=$(readlink -f "$0")

# --- Command Prefix for Sudo ---
SUDO_CMD=""
if [[ $EUID -ne 0 ]]; then
    SUDO_CMD="sudo"
fi

# --- Unified Configuration Paths ---
CONFIG_DIR="/home/${CURRENT_USER}/.config/docker_tool_suite"
CONFIG_FILE="${CONFIG_DIR}/config.conf"

# --- SHARED UI FUNCTION ---
# Usage: print_standard_menu "Title" array_reference "footer_mode(RQ|Q)"
print_standard_menu() {
    local title="$1"
    local -n _menu_options="$2" # uses nameref
    local footer_mode="${3:-RQ}" # Default to Return & Quit

    clear
    echo -e "${C_RESET}=============================================="
    echo -e " ${C_GREEN}${title}"
    echo -e "${C_RESET}=============================================="
    
    echo -e " ${C_YELLOW}Options: "
    # Loop through the passed options array
    for i in "${!_menu_options[@]}"; do
        echo -e " ${C_BLUE}$((i+1))${C_YELLOW}) ${C_RESET}${_menu_options[$i]}"
    done
    
    echo -e "${C_RESET}----------------------------------------------"
    
    # Display Footer based on mode
    if [[ "$footer_mode" == "RQ" ]]; then
        for i in "${!optionsRandQ[@]}"; do echo -e " ${optionsRandQ[$i]}"; done
    elif [[ "$footer_mode" == "Q" ]]; then
        for i in "${!optionsOnlyQ[@]}"; do echo -e " ${optionsOnlyQ[$i]}"; done
    fi
    
    echo -e "${C_RESET}----------------------------------------------${C_RESET}"
}

# --- Encryption Helpers ---
get_secret_key() {
    # Use a stable machine-specific ID for the encryption key.
    if [[ -r /etc/machine-id ]]; then
        cat /etc/machine-id
    elif [[ -r /var/lib/dbus/machine-id ]]; then
        cat /var/lib/dbus/machine-id
    else
        # Fallback for systems without machine-id. This is less secure.
        log "Warning: machine-id not found. Using hostname as a fallback for encryption key."
        hostname
    fi
}

encrypt_pass() {
    local plaintext="$1"
    local key
    key=$(get_secret_key)
    # Encrypt with AES-256, base64 encode, and remove newlines for single-line storage.
    printf '%s' "$plaintext" | openssl enc -aes-256-cbc -a -salt -pbkdf2 -pass pass:"$key" | tr -d '\n'
}

decrypt_pass() {
    local encrypted_text="$1"
    local key
    key=$(get_secret_key)
    # Decrypt the base64 encoded string. A newline is required for openssl to correctly process the piped base64 string.
    # The '|| true' prevents the script from exiting on decryption failure (e.g., empty input or wrong key).
    printf '%s\n' "$encrypted_text" | openssl enc -aes-256-cbc -a -d -salt -pbkdf2 -pass pass:"$key" 2>/dev/null || true
}

_record_image_state() {
    local app_dir="$1"
    local image_name="$2"
    local image_id="$3"
    local history_file="${app_dir}/.update_history"

    if [[ "$image_id" == "not_found" || -z "$image_id" ]]; then return; fi

    # Format: Timestamp | Image Name | Image ID
    local entry="$(date +'%Y-%m-%d %H:%M:%S')|${image_name}|${image_id}"
    
    # Check if the last entry is identical to avoid duplicates (e.g., repeated runs with no updates)
    local last_entry
    if [[ -f "$history_file" ]]; then
        last_entry=$(tail -n 1 "$history_file")
        # Extract just the image and ID part to compare
        if [[ "${last_entry#*|}" == "${image_name}|${image_id}" ]]; then
            return # Skip duplicate
        fi
    fi

    echo "$entry" >> "$history_file"
    
    # Keep file size manageable (keep last 50 entries)
    if [ $(wc -l < "$history_file") -gt 50 ]; then
        local temp_hist; temp_hist=$(mktemp)
        tail -n 50 "$history_file" > "$temp_hist"
        mv "$temp_hist" "$history_file"
    fi
}

# --- check_root now authenticates on demand ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${C_YELLOW}This action requires root privileges. Please enter your password.${C_RESET}"
        if ! sudo -v; then
            echo -e "${C_RED}Authentication failed. Aborting.${C_RESET}" >&2
            exit 1
        fi
        echo -e "${C_GREEN}Authentication successful.${C_RESET}\n"
    fi
}

log() {
    if [[ -n "${LOG_FILE-}" && "$IS_CRON_RUN" == "false" ]]; then echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; fi
    if [[ -n "${2-}" ]]; then echo -e "$2"; fi
}

execute_and_log() {
    if $DRY_RUN; then
        # Use printf for safer printing of arguments
        printf "${C_GRAY}[DRY RUN] Would execute: %q${C_RESET}\n" "$@"
        return 0 # Assume success in dry run mode
    fi

    local tmp_log; tmp_log=$(mktemp)
    local tail_pid

    tail -f "$tmp_log" &> /dev/null &
    tail_pid=$!

    "$@" &> "$tmp_log"
    local exit_code=$?

    sleep 0.1
    kill "$tail_pid" 2>/dev/null || true

    # Only append to the main log file if not running from cron.
    if [[ "$IS_CRON_RUN" == "false" ]]; then
        cat "$tmp_log" >> "${LOG_FILE:-/dev/null}"
    fi
    rm -f "$tmp_log"

    return "$exit_code"
}


check_deps() {
    log "Checking dependencies..." "${C_GRAY}Checking dependencies...${C_RESET}"
    local error_found=false
    # Use $SUDO_CMD
    if ! command -v docker &>/dev/null; then log "Error: Docker not found." "${C_RED}Error: Docker is not installed...${C_RESET}"; error_found=true; fi
    if ! $SUDO_CMD docker compose version &>/dev/null; then log "Error: Docker Compose V2 not found." "${C_RED}Error: Docker Compose V2 not available...${C_RESET}"; error_found=true; fi
    if ! command -v openssl &>/dev/null; then log "Error: openssl not found." "${C_RED}Error: 'openssl' is not installed (required for password encryption)...${C_RESET}"; error_found=true; fi
    if ! command -v rar &>/dev/null; then log "Warning: 'rar' command not found." "${C_YELLOW}Warning: 'rar' is not installed (optional, for creating secure archives)...${C_RESET}"; fi
    if $error_found; then exit 1; fi
    log "Dependencies check passed." ""
}

find_compose_file() {
    local app_dir="$1"
    local compose_files=("compose.yaml" "compose.yml" "docker-compose.yaml" "docker-compose.yml")
    for file in "${compose_files[@]}"; do if [ -f "$app_dir/$file" ]; then echo "$app_dir/$file"; return 0; fi; done
    return 1
}

discover_apps() {
    local path="$1"; local -n app_array="$2"
    app_array=()
    if [ ! -d "$path" ]; then echo "Warning: Directory not found for discovery: $path" >> "${LOG_FILE:-/dev/null}"; return; fi
    shopt -s nullglob # Prevent errors if no directories match
    
    # Note the trailing slash to match only directories
    for dir in "$path"/*/; do
        if [ -d "$dir" ]; then
            # Check if a compose file exists before considering it an app
            if find_compose_file "${dir%/}" &>/dev/null; then
                app_array+=("$(basename "$dir")")
            fi
        fi
    done
    
    shopt -u nullglob # Reset globbing behavior
    IFS=$'\n' app_array=($(sort <<<"${app_array[*]}")); unset IFS
}

show_selection_menu() {
    local title="$1" action_verb="$2"; local -n all_items_ref="$3"; local -n selected_status_ref="$4"
    while true; do
        clear
        echo -e "====================================================="
        echo -e " ${C_GREEN}${title}${C_RESET}"
        echo -e "====================================================="
        for i in "${!all_items_ref[@]}"; do
            if ${selected_status_ref[$i]}; then echo -e " $((i+1)). ${C_GREEN}[x]${C_RESET} ${all_items_ref[$i]}"; else echo -e " $((i+1)). ${C_RED}[ ]${C_RESET} ${all_items_ref[$i]}"; fi
        done
        echo "-----------------------------------------------------"
        echo -e "Enter a (${C_GREEN}No.${C_RESET}) to toggle, ${C_BLUE}(a)ll${C_RESET}, ${C_YELLOW}(${action_verb}) ${C_RESET}to ${C_YELLOW}${action_verb}${C_RESET}, ${C_GRAY}(r)eturn ${C_RESET}or ${C_RED}(q)uit${C_RESET}."
        read -rp "Your choice: " choice
        case "$choice" in
            "${action_verb}")
                local any_selected=false
                for status in "${selected_status_ref[@]}"; do
                    if $status; then any_selected=true; break; fi
                done
                if ! $any_selected; then
                    echo -e "${C_YELLOW}No items selected. Press Enter to continue...${C_RESET}"; read -r
                    continue
                fi
                return 0
                ;;
            [rR]) return 1 ;;
            [qQ]) exit 0 ;;
            [aA])
                local all_selected=true; for status in "${selected_status_ref[@]}"; do if ! $status; then all_selected=false; break; fi; done
                local new_status; new_status=$(if $all_selected; then echo "false"; else echo "true"; fi)
                for i in "${!selected_status_ref[@]}"; do selected_status_ref[$i]=$new_status; done ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#all_items_ref[@]}" ]; then
                    local index=$((choice-1))
                    if ${selected_status_ref[$index]}; then selected_status_ref[$index]=false; else selected_status_ref[$index]=true; fi
                else
                    echo -e "${C_RED}Invalid input. Press Enter to continue...${C_RESET}"; read -r
                fi ;;
        esac
    done
}

interactive_list_builder() {
    local title="$1"; local -n source_array="$2"; local -n result_array="$3"
    result_array=()
    if [[ ${#source_array[@]} -eq 0 ]]; then echo -e "${C_YELLOW}No items found to configure. Skipping.${C_RESET}"; sleep 2; return; fi
    local -a selected_status=(); for ((i=0; i<${#source_array[@]}; i++)); do selected_status+=("false"); done
    if ! show_selection_menu "$title" "confirm" source_array selected_status; then return; fi
    for i in "${!source_array[@]}"; do if ${selected_status[$i]}; then result_array+=("${source_array[$i]}"); fi; done
}

initial_setup() {
    # This function must be run as root
    if [[ $EUID -ne 0 ]]; then echo -e "${C_RED}Initial setup must be run with 'sudo ./docker_tool_suite.sh'. Exiting.${C_RESET}"; exit 1; fi
    clear
    echo -e "${C_RESET}================================================"
    echo -e "${C_GREEN} Welcome to the ${C_BLUE}Docker Tool Suite ${SCRIPT_VERSION} ${C_GREEN}Setup!"
    echo -e "${C_RESET}================================================\n"
    echo -e "${C_YELLOW}This one-time setup will configure all modules.\n"
    echo -e "${C_RESET}Settings will be saved to: ${C_GREEN}${CONFIG_FILE}${C_RESET}\n"

    local apps_path_def="/home/${CURRENT_USER}/apps"
    local managed_subdir_def="managed_stacks"
    local backup_path_def="/home/${CURRENT_USER}/backups/docker-volume-backups"
    local restore_path_def="/home/${CURRENT_USER}/backups/docker-volume-restore-dir"
    local log_dir_def="/home/${CURRENT_USER}/logs/docker_tool_suite"
    local log_retention_def="30"
    
    echo -e "-----------------------------------------------------\n"
    echo -e "${C_YELLOW}--- Configure Path Settings ---${C_RESET}\n"
    echo -e "${C_GRAY}Leave the defualt paths or enter your own. \n${C_RESET}"
    read -p "Base Compose Apps Path [${C_GREEN}${apps_path_def}${C_RESET}]: " apps_path; APPS_BASE_PATH=${apps_path:-$apps_path_def}
    read -p "Managed Apps Subdirectory [${C_GREEN}${managed_subdir_def}${C_RESET}]: " managed_subdir; MANAGED_SUBDIR=${managed_subdir:-$managed_subdir_def}
    read -p "Default Backup Location [${C_GREEN}${backup_path_def}${C_RESET}]: " backup_loc; BACKUP_LOCATION=${backup_loc:-$backup_path_def}
    read -p "Default Restore Location [${C_GREEN}${restore_path_def}${C_RESET}]: " restore_loc; RESTORE_LOCATION=${restore_loc:-$restore_path_def}
    read -p "Log Directory Path [${C_GREEN}${log_dir_def}${C_RESET}]: " log_dir; LOG_DIR=${log_dir:-$log_dir_def}
    read -p "Log file retention period (days, 0 to disable) [${C_GREEN}${log_retention_def}${C_RESET}]: " log_retention; LOG_RETENTION_DAYS=${log_retention:-$log_retention_def}
    
    echo -e "\n${C_YELLOW}--- Configure Helper Images ---${C_RESET}"
    local backup_image_def="docker/alpine-tar-zstd:latest"
    local explore_image_def="debian:trixie-slim"
    
    read -p "Backup Helper Image [${C_GREEN}${backup_image_def}${C_RESET}]: " bk_img
    BACKUP_IMAGE=${bk_img:-$backup_image_def}
    
    read -p "Volume Explorer Image [${C_GREEN}${explore_image_def}${C_RESET}]: " exp_img
    EXPLORE_IMAGE=${exp_img:-$explore_image_def}

    local -a selected_ignored_volumes=()
    read -p $'\n'"Do you want to configure ignored volumes now? (y/N): " config_vols
    if [[ "${config_vols,,}" =~ ^(y|Y|yes|YES)$ ]]; then
        mapfile -t all_volumes < <(docker volume ls --format "{{.Name}}" | sort)
        interactive_list_builder "Select Volumes to IGNORE during backup" all_volumes selected_ignored_volumes
    fi
    
    local -a selected_ignored_images=()
    read -p $'\n'"Do you want to configure ignored images now? (y/N): " config_imgs
    if [[ "${config_imgs,,}" =~ ^(y|Y|yes|YES)$ ]]; then
        mapfile -t all_images < <(docker image ls --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>" | sort)
        interactive_list_builder "Select Images to IGNORE during updates" all_images selected_ignored_images
    fi

    echo -e "\n${C_YELLOW}--- Secure Archive Settings (Optional) ---${C_RESET}"
    local rar_pass_1 rar_pass_2 ENCRYPTED_RAR_PASSWORD=""

    while true; do
        echo -e "${C_GRAY}This password will be used to encrypt RAR backups by default.${C_RESET}"
        read -sp "Enter a default password (leave blank for none): " rar_pass_1; echo

        if [[ -z "$rar_pass_1" ]]; then
            # Added Check: Ask for confirmation if they really meant no password
            read -p "${C_YELLOW}You left the password blank. Disable default encryption? (Y/n): ${C_RESET}" confirm_no_pass
            if [[ "${confirm_no_pass:-y}" =~ ^[Yy]$ ]]; then
                echo -e "${C_GREEN}-> Default encryption disabled.${C_RESET}"
                ENCRYPTED_RAR_PASSWORD=""
                break
            else
                echo -e "${C_BLUE}-> Please enter a password then.${C_RESET}"
                continue
            fi
        fi

        read -sp "Confirm password: " rar_pass_2; echo

        if [[ "$rar_pass_1" == "$rar_pass_2" ]]; then
            ENCRYPTED_RAR_PASSWORD=$(encrypt_pass "${rar_pass_1}")
            echo -e "${C_GREEN}-> Password saved and encrypted.${C_RESET}"
            break
        else
            echo -e "${C_RED}Passwords do not match. Please try again.${C_RESET}"
        fi
    done

    read -p "Default RAR Compression Level (0-5) [${C_GREEN}3${C_RESET}]: " rar_level
    RAR_COMPRESSION_LEVEL=${rar_level:-3}

    clear
    echo -e "\n${C_GREEN}_--| Docker Tool Suite ${SCRIPT_VERSION} Setup |---_${C_RESET}\n"
    echo -e "${C_YELLOW}--- Configuration Summary ---${C_RESET}"
    echo "  App Manager:"
    echo -e "    Base Path:       ${C_GREEN}${APPS_BASE_PATH}${C_RESET}"
    echo -e "    Managed Subdir:  ${C_GREEN}${MANAGED_SUBDIR}${C_RESET}"
    echo "  Volume Manager:"
    echo -e "    Backup Path:     ${C_GREEN}${BACKUP_LOCATION}${C_RESET}"
    echo -e "    Restore Path:    ${C_GREEN}${RESTORE_LOCATION}${C_RESET}"
    echo "  Archive Settings:"
    echo -e "    RAR Level:       ${C_GREEN}${RAR_COMPRESSION_LEVEL}${C_RESET}"
    echo "  General:"
    echo -e "    Log Path:        ${C_GREEN}${LOG_DIR}${C_RESET}"
    echo -e "    Log Retention:   ${C_GREEN}${LOG_RETENTION_DAYS} days${C_RESET}\n"
    
    read -p "Save this configuration? (Y/n): " confirm_setup
    if [[ ! "${confirm_setup,,}" =~ ^(y|Y|yes|YES)$ ]]; then echo -e "\n${C_RED}Setup canceled.${C_RESET}"; exit 0; fi

    echo -e "\n${C_GREEN}Saving configuration...${C_RESET}"; mkdir -p "${CONFIG_DIR}"
    {
        echo "# ============================================="
        echo "#  Unified Configuration for Docker Tool Suite"
        echo "# ============================================="
        echo
        echo "# --- App Manager ---"
        # Using double quotes for path variables as requested, which also handles spaces.
        printf "APPS_BASE_PATH=\"%s\"\n" "${APPS_BASE_PATH}"
        printf "MANAGED_SUBDIR=\"%s\"\n" "${MANAGED_SUBDIR}"
        echo
        echo "# --- Volume Manager ---"
        printf "BACKUP_LOCATION=\"%s\"\n" "${BACKUP_LOCATION}"
        printf "RESTORE_LOCATION=\"%s\"\n" "${RESTORE_LOCATION}"

        echo "# Image used for backup/restore operations (must have tar and zstd)"
        printf "BACKUP_IMAGE=\"%s\"\n" "${BACKUP_IMAGE}"
        echo "# Image used for the interactive shell explorer"
        printf "EXPLORE_IMAGE=\"%s\"\n" "${EXPLORE_IMAGE}"

        echo
        echo "# List of volumes to ignore during backup."
        echo -n "IGNORED_VOLUMES=("
        if [ ${#selected_ignored_volumes[@]} -gt 0 ]; then
            printf "\n"; for vol in "${selected_ignored_volumes[@]}"; do echo "    \"$vol\""; done
        else
            printf "\n"; echo "    \"example-of-ignored_volume-1\""
            printf "\n"; echo "    \"example-of-ignored_volume-2\""
        fi
        echo ")"
        echo
        echo "# List of images to ignore during updates (e.g., custom builds or pinned versions)."
        echo -n "IGNORED_IMAGES=("
        if [ ${#selected_ignored_images[@]} -gt 0 ]; then
            printf "\n"; for img in "${selected_ignored_images[@]}"; do echo "    \"$img\""; done
        else
            printf "\n"; echo "    \"custom-registry/my-custom-app-1:latest\""
            printf "\n"; echo "    \"custom-registry/my-custom-app-2:latest\""
        fi
        echo ")"
        echo
        echo "# --- Secure Archive (RAR) ---"
        echo "# RAR Password is encrypted using a machine-specific key."
        printf "ENCRYPTED_RAR_PASSWORD=%q\n" "${ENCRYPTED_RAR_PASSWORD}"
        echo "RAR_COMPRESSION_LEVEL=${RAR_COMPRESSION_LEVEL}"
        echo
        echo "# --- General ---"
        printf "LOG_DIR=\"%s\"\n" "${LOG_DIR}"
        echo "# Log file retention period in days. Set to 0 to disable automatic pruning."
        printf "LOG_RETENTION_DAYS=%s\n" "${LOG_RETENTION_DAYS}"
    } > "${CONFIG_FILE}"

    echo -e "${C_YELLOW}Creating directories and setting permissions...${C_RESET}"
    mkdir -p "${APPS_BASE_PATH}/${MANAGED_SUBDIR}" "${BACKUP_LOCATION}" "${RESTORE_LOCATION}" "${LOG_DIR}"
    chown -R "${CURRENT_USER}:${CURRENT_USER}" "${CONFIG_DIR}" "${APPS_BASE_PATH}" "${BACKUP_LOCATION}" "${RESTORE_LOCATION}" "${LOG_DIR}"

    setup_cron_job

    echo -e "\n${C_GREEN}${TICKMARK} Setup complete! The script will now continue.${C_RESET}\n"; sleep 2
}

setup_cron_job() {
    echo -e "\n${C_YELLOW}--- Optional: Schedule Automatic App Updates ---${C_RESET}"
    read -p "Would you like to schedule the app updater to run automatically? (Y/n): " schedule_now
    if [[ ! "$(echo "${schedule_now:-y}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|Y|yes|YES)$ ]]; then
        echo -e "${C_YELLOW}Skipping cron job setup.${C_RESET}"; return
    fi
    
    local cron_target_user="root"
    echo "The script needs Docker permissions to run. We recommend running the scheduled task as 'root'."
    read -p "Run the scheduled task as 'root'? (Y/n): " confirm_root
    if [[ ! "$(echo "${confirm_root:-y}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|Y|yes|YES)$ ]]; then
        echo -e "${C_YELLOW}Cron job setup canceled.${C_RESET}"; return
    fi

    local cron_schedule=""
    while true; do
        clear
        echo -e "${C_YELLOW}Choose a schedule for the app updater (for user: ${C_GREEN}$cron_target_user${C_YELLOW}):${C_RESET}\n"
        echo "   --- Special & Frequent ---           --- Daily & Weekly ---"
        echo "   1) At every reboot                   6) Daily (at 4 AM)"
        echo "   2) Every hour                        7) Weekly (Sunday at midnight)"
        echo "   3) Every 6 hours                     8) Weekly (Saturday at 4 AM)"
        echo "   4) Every 12 hours"
        echo "   5) Daily (at midnight)"
        echo
        echo "   --- Monthly & Custom ---"
        echo "   9) Monthly (1st of month at 4 AM)"
        echo "  10) Custom"
        echo "  11) Cancel"
        echo
        read -p "Enter your choice [1-11]: " choice
        case $choice in
            1) cron_schedule="@reboot"; break ;;
            2) cron_schedule="0 * * * *"; break ;;
            3) cron_schedule="0 */6 * * *"; break ;;
            4) cron_schedule="0 */12 * * *"; break ;;
            5) cron_schedule="0 0 * * *"; break ;;
            6) cron_schedule="0 4 * * *"; break ;;
            7) cron_schedule="0 0 * * 0"; break ;;
            8) cron_schedule="0 4 * * 6"; break ;;
            9) cron_schedule="0 4 1 * *"; break ;;
            10) read -p "Enter custom cron schedule (e.g., '30 2 * * *' for 2:30 AM daily): " custom_cron
                if [[ -n "$custom_cron" ]]; then cron_schedule="$custom_cron"; break; fi ;;
            11) echo -e "${C_YELLOW}Cron job setup canceled.${C_RESET}"; return ;;
            *) echo -e "${C_RED}Invalid option. Please try again.${C_RESET}"; sleep 1 ;;
        esac
    done

    echo -e "\n${C_YELLOW}Adding job to root's crontab...${C_RESET}"
    local cron_command="$cron_schedule $SUDO_CMD $SCRIPT_PATH update --cron"
    local cron_comment="# Added by Docker Tool Suite to update application images"
    
    local current_crontab; current_crontab=$(crontab -u "$cron_target_user" -l 2>/dev/null || true)
    
    if echo "$current_crontab" | grep -Fq "$SCRIPT_PATH"; then
        echo -e "${C_YELLOW}A cron job for this script already exists. Skipping.${C_RESET}"
    else
        local new_crontab
        new_crontab=$(printf "%s\n%s\n%s\n" "$current_crontab" "$cron_comment" "$cron_command")

        if ! echo "$new_crontab" | crontab -u "$cron_target_user" -; then
            echo -e "${C_RED}Error: Failed to install the cron job. The schedule '$cron_schedule' might be invalid.${C_RESET}"
            echo -e "${C_YELLOW}Crontab was not modified.${C_RESET}"
            return 1
        fi
        echo -e "${C_GREEN}${TICKMARK} Cron job added successfully!${C_RESET}"
    fi
}

# ======================================================================================
# --- SECTION 2: APPLICATION MANAGER MODULE ---
# ======================================================================================

_start_app_task() {
    local app_name="$1" app_dir="$2"
    local extra_args="${3:-}" # Accept optional arguments

    log "Starting $app_name..."
    local compose_file; compose_file=$(find_compose_file "$app_dir")
    if [ -z "$compose_file" ]; then log "Warning: No compose file for '$app_name'. Skipping." ""; return; fi
    
    log "Pulling images for '$app_name'..."
    # We generally want to ensure images exist, but 'up' will do it too. 
    # Explicit pull is safer for ensuring we have what we expect before starting.
    if execute_and_log $SUDO_CMD docker compose -f "$compose_file" pull; then
        log "Starting containers for '$app_name' (Args: ${extra_args:-none})..."
        # Pass extra_args (like --force-recreate) to the command
        execute_and_log $SUDO_CMD docker compose -f "$compose_file" up -d $extra_args
        log "Successfully started '$app_name'."
    else
        log "ERROR: Failed to pull images for '$app_name'. Aborting start."
        echo -e "${C_BOLD_RED}Failed to pull images for '$app_name'. Check log for details.${C_RESET}"
    fi
}

_stop_app_task() {
    local app_name="$1" app_dir="$2"
    log "Stopping $app_name..."
    local compose_file; compose_file=$(find_compose_file "$app_dir")
    if [ -z "$compose_file" ]; then log "Info: No compose file for '$app_name'. Cannot stop." ""; return; fi
    
    execute_and_log $SUDO_CMD docker compose -f "$compose_file" down --remove-orphans
    log "Successfully stopped '$app_name'."
}

_update_app_task() {
    local app_name="$1" app_dir="$2"
    local force_mode="${3:-false}"

    log "Updating $app_name (Force Mode: $force_mode)..."
    local compose_file; compose_file=$(find_compose_file "$app_dir")
    if [ -z "$compose_file" ]; then log "Warning: No compose file for '$app_name'. Skipping." ""; return; fi
    
    local was_running=false
    if $SUDO_CMD docker compose -f "$compose_file" ps --status=running | grep -q 'running'; then
        was_running=true
    fi

    # --- Step 1: Image Pull & Update Detection ---
    log "Checking for images to update for '$app_name'..."
    mapfile -t all_app_images < <($SUDO_CMD docker compose -f "$compose_file" config --images 2>/dev/null)
    
    local -a images_to_pull=()
    local all_pulls_succeeded=true
    local update_was_found=false 

    if [[ "$force_mode" == "true" ]]; then
        update_was_found=true
        log "Force mode enabled: Containers will be recreated."
    fi

    if [ ${#all_app_images[@]} -eq 0 ]; then
        log "No images defined in compose file for $app_name."
    else
        for image in "${all_app_images[@]}"; do
            if [[ " ${IGNORED_IMAGES[*]-} " =~ " ${image} " ]]; then
                log "Skipping ignored image: $image" "   -> Skipping ignored image: ${C_GRAY}${image}${C_RESET}"
            else
                images_to_pull+=("$image")
            fi
        done

        if [ ${#images_to_pull[@]} -gt 0 ]; then
            echo -e "Pulling latest versions for non-ignored images in ${C_YELLOW}${app_name}${C_RESET}..."
            for image in "${images_to_pull[@]}"; do
                log "Checking image: $image" "   -> Checking ${C_BLUE}${image}${C_RESET}..."
                
                # 1. Capture Image ID BEFORE the pull
                local id_before
                id_before=$($SUDO_CMD docker inspect --format='{{.Id}}' "$image" 2>/dev/null || echo "not_found")

                # --- Record History ---
                _record_image_state "$app_dir" "$image" "$id_before"
                # ---------------------------

                # 2. Perform the pull
                local pull_output; pull_output=$($SUDO_CMD docker pull "$image" 2>&1)
                local pull_exit_code=$?
                echo "$pull_output" >> "${LOG_FILE:-/dev/null}"
                
                if [ "$pull_exit_code" -ne 0 ]; then
                    log "ERROR: Failed to pull image $image" "${C_BOLD_RED}Failed to pull ${image}. See log for details.${C_RESET}"
                    all_pulls_succeeded=false
                else
                    # 3. Capture Image ID AFTER the pull
                    local id_after
                    id_after=$($SUDO_CMD docker inspect --format='{{.Id}}' "$image" 2>/dev/null)

                    # 4. Compare IDs
                    if [[ "$id_before" != "$id_after" ]] || [[ "$id_before" == "not_found" ]]; then
                        log "New image found for $image (Hash changed)." "   -> ${C_GREEN}Newer image downloaded!${C_RESET}"
                        update_was_found=true
                    else
                        log "Image $image is up to date."
                    fi
                fi
            done
        fi
    fi

    # --- Step 2: Restart Application ---
    if $all_pulls_succeeded; then
        if $was_running || [[ "$force_mode" == "true" ]]; then
            if $update_was_found; then
                local restart_msg="Restarting"
                local start_args=""
                
                if [[ "$force_mode" == "true" ]]; then
                    echo -e "${C_GREEN}Force Recreate enabled. Recreating containers for '$app_name'...${C_RESET}"
                    restart_msg="Force recreating"
                    start_args="--force-recreate"
                else
                    echo -e "${C_GREEN}New image(s) found. Restarting '$app_name' to apply updates...${C_RESET}"
                fi

                log "$restart_msg '$app_name'..."
                _stop_app_task "$app_name" "$app_dir"
                _start_app_task "$app_name" "$app_dir" "$start_args"
                
                log "Successfully updated/recreated '$app_name'."
            else
                log "App up to date. No action."
                echo -e "All images for ${C_YELLOW}${app_name}${C_RESET} are up to date. No action taken."
            fi
        else
            log "Application '$app_name' was not running. Images checked, but app remains stopped."
        fi
    else
        log "ERROR: Failed to pull images for '$app_name'. Aborting."
        echo -e "${C_BOLD_RED}Update for '$app_name' aborted due to pull failures.${C_RESET}"
    fi
}

_rollback_app_task() {
    local app_name="$1" app_dir="$2"
    local history_file="${app_dir}/.update_history"
    
    clear
    echo -e "${C_YELLOW}--- Rollback Wizard for ${app_name} ---${C_RESET}"
    
    if [[ ! -f "$history_file" ]]; then
        echo -e "${C_RED}No update history found for this app.${C_RESET}"
        echo "History is only created when you run updates via this tool."
        read -p "Press Enter to return..."
        return
    fi

    # Read history into array (reversed to show newest first)
    # Uses sed '1!G;h;$!d' as a portable replacement for 'tac'
    mapfile -t history_lines < <(sed '1!G;h;$!d' "$history_file")
    
    if [ ${#history_lines[@]} -eq 0 ]; then
        echo -e "${C_YELLOW}History file is empty.${C_RESET}"; read -p "Press Enter..." ; return
    fi

    echo "Select a previous state to restore:"
    echo "----------------------------------------------------------------"
    printf "%-4s | %-20s | %-30s | %s\n" "No." "Date" "Image Name" "ID (Hash)"
    echo "----------------------------------------------------------------"

    local -a valid_choices=()
    local display_count=0
    
    for line in "${history_lines[@]}"; do
        IFS='|' read -r timestamp img_name img_id <<< "$line"
        
        # Check if this ID still exists locally
        if $SUDO_CMD docker image inspect "$img_id" &>/dev/null; then
            local short_id="${img_id:7:12}" # Remove sha256: and truncate
            printf "%-4s | %-20s | %-30s | %s\n" "$((display_count+1))" "$timestamp" "${img_name:0:28}.." "$short_id"
            valid_choices+=("$line")
            ((display_count++))
        else
            # Optional: indicate pruned images? For now, just skip them to keep the list clean.
            continue
        fi
        
        # Limit to last 10 valid options
        if [ $display_count -ge 10 ]; then break; fi
    done
    echo "----------------------------------------------------------------"

    if [ ${#valid_choices[@]} -eq 0 ]; then
        echo -e "${C_RED}No locally available images found in history.${C_RESET}"
        echo "The previous versions may have been pruned by a cleanup task."
        read -p "Press Enter..."
        return
    fi

    read -p "Enter number to rollback to (or 'q' to cancel): " choice
    if [[ "${choice,,}" == "q" ]]; then return; fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#valid_choices[@]}" ]; then
        local selected_line="${valid_choices[$((choice-1))]}"
        IFS='|' read -r r_time r_name r_id <<< "$selected_line"

        echo -e "\n${C_BOLD_RED}WARNING: This will force '${r_name}' to point to ID '${r_id:7:12}' locally.${C_RESET}"
        read -p "Are you sure? (y/N): " confirm
        if [[ "${confirm,,}" =~ ^(y|Y|yes|YES)$ ]]; then
            log "Rolling back $app_name image $r_name to $r_id..."
            
            # 1. Retag the old ID to the current name
            if execute_and_log $SUDO_CMD docker tag "$r_id" "$r_name"; then
                echo -e "${C_GREEN}Image successfully retagged.${C_RESET}"
                
                # 2. Restart the app
                echo "Restarting application to apply change..."
                _stop_app_task "$app_name" "$app_dir"
                _start_app_task "$app_name" "$app_dir" "--force-recreate"
                
                echo -e "\n${C_GREEN}${TICKMARK} Rollback complete.${C_RESET}"
                log "Rollback successful for $r_name."
            else
                echo -e "${C_RED}Error: Failed to retag image.${C_RESET}"
            fi
        else
            echo "Rollback canceled."
        fi
    else
        echo -e "${C_RED}Invalid selection.${C_RESET}"
    fi
    read -p "Press Enter to continue..."
}

app_manager_status() {
    clear; log "Generating App Status Overview" "${C_BLUE}Displaying App Status Overview...${C_RESET}"
    local less_prompt="(Scroll with arrow keys, press 'q' to return)"
    (
        declare -A running_projects
        # This is a more robust method to find running projects, less prone to breaking with docker updates.
        while read -r proj; do
            [[ -n "$proj" ]] && running_projects["$proj"]=1
        done < <($SUDO_CMD docker compose ls | grep 'running' | awk '{print $1}')

        echo -e "================ App Status Overview ================\n"
        echo -e "${C_YELLOW}--- Essential Apps (${APPS_BASE_PATH}) ---${C_RESET}"
        local -a essential_apps; discover_apps "$APPS_BASE_PATH" essential_apps
        if [ ${#essential_apps[@]} -eq 0 ]; then echo "No essential apps found."; else
            for app in "${essential_apps[@]}"; do
                if [ "$app" != "$MANAGED_SUBDIR" ]; then
                    if [[ -v running_projects[$app] ]]; then echo -e " ${C_GREEN}[RUNNING]${C_RESET}\t$app"; else echo -e " ${C_RED}[STOPPED]${C_RESET}\t$app"; fi
                fi
            done
        fi
        echo -e "\n${C_YELLOW}--- Managed Apps (${MANAGED_SUBDIR}) ---${C_RESET}"
        local -a managed_apps; local managed_path="$APPS_BASE_PATH/$MANAGED_SUBDIR"; discover_apps "$managed_path" managed_apps
        if [ ${#managed_apps[@]} -eq 0 ]; then echo "No managed apps found."; else
            for app in "${managed_apps[@]}"; do
                if [[ -v running_projects[$app] ]]; then echo -e " ${C_GREEN}[RUNNING]${C_RESET}\t$app"; else echo -e " ${C_RED}[STOPPED]${C_RESET}\t$app"; fi
            done
        fi
        echo -e "\n===================================================="
    ) | less -RX --prompt="$less_prompt"
}

app_manager_interactive_handler() {
    local app_type_name="$1"
    local discovery_path="$2"
    local base_path="$3"

    while true; do
        # Options array
        local options=(
            "Start ${app_type_name} Apps"
            "Stop ${app_type_name} Apps"
            "Update ${app_type_name} Apps"
            "Rollback ${app_type_name} Apps"
        )
        
        # Use shared UI function
        print_standard_menu "Manage ${app_type_name} Apps" options "RQ"
        
        read -rp "${C_YELLOW}Please select an option: ${C_RESET}" choice

        local action=""
        local title=""
        local task_func=""
        local menu_action_key=""
        local force_flag="false"

        case "$choice" in
            1)
                action="start"; title="Select ${app_type_name} Apps to START"; task_func="_start_app_task"; menu_action_key="start" ;;
            2)
                action="stop"; title="Select ${app_type_name} Apps to STOP"; task_func="_stop_app_task"; menu_action_key="stop" ;;
            3)
                action="update"; title="Select ${app_type_name} Apps to UPDATE"; task_func="_update_app_task"; menu_action_key="update"
                echo ""
                read -p "Force recreate containers even if no updates found? (useful for config changes) [y/N]: " force_choice
                if [[ "${force_choice,,}" =~ ^(y|Y|yes|YES)$ ]]; then
                    force_flag="true"
                    title="${title} (FORCE RECREATE)"
                fi
                ;;
            4)
                action="rollback"; title="Select ONE App to Rollback"; task_func="_rollback_app_task"; menu_action_key="rollback"
                ;;
            [rR]) return ;;
            [qQ]) exit 0 ;;
            *) echo -e "\n${C_RED}Invalid option.${C_RESET}"; sleep 1; continue ;;
        esac

        local -a all_apps; discover_apps "$discovery_path" all_apps
        
        if [[ "$app_type_name" == "Essential" ]]; then
            local -a filtered_apps=()
            for app in "${all_apps[@]}"; do
                if [[ "$app" != "$MANAGED_SUBDIR" ]]; then
                    filtered_apps+=("$app")
                fi
            done
            all_apps=("${filtered_apps[@]}")
        fi
        
        if [ ${#all_apps[@]} -eq 0 ]; then
            log "No ${app_type_name} apps found for this action." "${C_YELLOW}No ${app_type_name} apps found.${C_RESET}"; sleep 2; continue
        fi
        
        local -a selected_status=()
        if [[ "$action" == "stop" || "$action" == "update" ]]; then
            [[ "$force_flag" == "false" ]] && title+=" (defaults to running)"
            declare -A running_apps_map
            while read -r project; do [[ -n "$project" ]] && running_apps_map["$project"]=1; done < <($SUDO_CMD docker compose ls --quiet)
            for app in "${all_apps[@]}"; do
                if [[ -v running_apps_map[$app] ]]; then selected_status+=("true"); else selected_status+=("false"); fi
            done
        else
            for ((i=0; i<${#all_apps[@]}; i++)); do selected_status+=("false"); done
        fi

        local menu_result; show_selection_menu "$title" "$menu_action_key" all_apps selected_status
        menu_result=$?

        if [[ $menu_result -eq 1 ]]; then log "User quit. No action taken." ""; continue; fi
        
        # Check for multiple selections in Rollback mode
        if [[ "$action" == "rollback" ]]; then
            local count=0
            for i in "${!selected_status[@]}"; do
                if ${selected_status[$i]}; then ((count+=1)); fi
            done
            
            if [ $count -gt 1 ]; then
                 echo -e "${C_RED}Rollback only supports one app at a time. Please select only one.${C_RESET}"; sleep 2; continue
            fi
            if [ $count -eq 0 ]; then
                 echo -e "${C_YELLOW}No app selected.${C_RESET}"; sleep 1; continue
            fi
        fi

        log "Performing '$action' on selected ${app_type_name} apps" "${C_GREEN}Processing selected apps...${C_RESET}\n"
        for i in "${!all_apps[@]}"; do
            if ${selected_status[$i]}; then 
                if [[ "$task_func" == "_update_app_task" ]]; then
                    $task_func "${all_apps[$i]}" "$base_path/${all_apps[$i]}" "$force_flag"
                else
                    $task_func "${all_apps[$i]}" "$base_path/${all_apps[$i]}"
                fi
            fi
        done
        
        if [[ "$action" != "rollback" ]]; then
            log "All selected ${app_type_name} app processes for '$action' finished."
            echo -e "\n${C_BLUE}Task complete. Press Enter...${C_RESET}"; read -r
        fi
    done
}

app_manager_update_all_known_apps() {
    check_root
    log "Starting update for RUNNING applications..."

    # --- Using a robust method to find running projects ---
    log "Discovering currently running Docker Compose projects..."
    declare -A running_projects
    # This is the most compatible method. It avoids --filter and --format flags,
    # which are failing on this system. It parses the default, human-readable
    # command output to find projects with a "running" status.
    while read -r proj; do
        [[ -n "$proj" ]] && running_projects["$proj"]=1
    done < <($SUDO_CMD docker compose ls | grep 'running' | awk '{print $1}')

    local -a essential_apps; discover_apps "$APPS_BASE_PATH" essential_apps
    local -a managed_apps; discover_apps "$APPS_BASE_PATH/$MANAGED_SUBDIR" managed_apps

    if [ ${#essential_apps[@]} -eq 0 ] && [ ${#managed_apps[@]} -eq 0 ]; then
        log "No applications found in any directory." "${C_YELLOW}No applications found to update.${C_RESET}"
        return
    fi

    log "Found essential and managed apps. Starting update process for running apps only..." "${C_GREEN}Updating all RUNNING applications...${C_RESET}"

    for app in "${essential_apps[@]}"; do
        if [[ "$app" != "$MANAGED_SUBDIR" ]]; then
            if [[ -v running_projects[$app] ]]; then
                echo -e "\n${C_BLUE}--- Updating RUNNING Essential App: ${C_YELLOW}${app}${C_BLUE} ---${C_RESET}"
                _update_app_task "$app" "$APPS_BASE_PATH/$app"
            else
                log "Skipping update for stopped essential app: $app"
            fi
        fi
    done

    for app in "${managed_apps[@]}"; do
        if [[ -v running_projects[$app] ]]; then
            echo -e "\n${C_BLUE}--- Updating RUNNING Managed App: ${C_YELLOW}${app}${C_BLUE} ---${C_RESET}"
            _update_app_task "$app" "$APPS_BASE_PATH/$MANAGED_SUBDIR/$app"
        else
            log "Skipping update for stopped managed app: $app"
        fi
    done

    log "Finished update task for all running applications." "${C_GREEN}\nFull update task finished.${C_RESET}"
}

app_manager_stop_all() {
    log "Stopping ALL running Docker Compose projects" "${C_YELLOW}Stopping all projects...${C_RESET}"
    local projects; projects=$($SUDO_CMD docker compose ls --quiet)
    if [ -z "$projects" ]; then log "No running projects found." "${C_GREEN}No running projects found to stop.${C_RESET}"; return; fi
    echo "$projects" | while read -r project; do
        if [ -n "$project" ]; then
            log "Stopping project: $project"
            execute_and_log $SUDO_CMD docker compose -p "$project" down --remove-orphans
        fi
    done
    log "All Docker Compose project stop processes finished."
}

app_manager_menu() {
    check_root
    local options=(
        "Show App STATUS"
        "Control ESSENTIAL Apps"
        "Control MANAGED Apps"
        "STOP ALL RUNNING APPS"
    )
    while true; do
        print_standard_menu "Application Manager" options "RQ"
        read -rp "${C_YELLOW}Please select an option: ${C_RESET}" choice
        case "$choice" in
            1) app_manager_status ;;
            2) app_manager_interactive_handler "Essential" "$APPS_BASE_PATH" "$APPS_BASE_PATH" ;;
            3) app_manager_interactive_handler "Managed" "$APPS_BASE_PATH/$MANAGED_SUBDIR" "$APPS_BASE_PATH/$MANAGED_SUBDIR" ;;
            4) 
                read -rp "$(printf "\n${C_BOLD_RED}This will stop ALL running compose applications. Are you sure? [y/N]: ${C_RESET}")" confirm
                if [[ "${confirm,,}" =~ ^(y|Y|yes|YES)$ ]]; then
                    app_manager_stop_all
                else
                    echo -e "\n${C_YELLOW}Operation canceled.${C_RESET}"
                fi
                echo -e "\n${C_BLUE}Task complete. Press Enter...${C_RESET}"; read -r
                ;;
            [rR]) return ;;
            [qQ]) log "Exiting script." "${C_GRAY}Exiting.${C_RESET}"; exit 0 ;;
            *) echo -e "\n${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
        esac
    done
}


# ======================================================================================
# --- SECTION 4: VOLUME MANAGER & CHECKER MODULE ---
# ======================================================================================

ensure_backup_image() {
    log "Checking for backup image: $BACKUP_IMAGE" "-> Checking for Docker image: ${C_BLUE}${BACKUP_IMAGE}${C_RESET}..."
    if ! $SUDO_CMD docker image inspect "${BACKUP_IMAGE}" &>/dev/null; then
        log "Image not found, pulling..." "   -> Image not found locally. Pulling..."
        if ! execute_and_log $SUDO_CMD docker pull "${BACKUP_IMAGE}"; then log "ERROR: Failed to pull backup image." "${C_RED}Error: Failed to pull...${C_RESET}"; exit 1; fi
    fi
    log "Backup image OK." "-> Image OK.\n"
}

ensure_explore_image() {
    log "Checking for explorer image: ${EXPLORE_IMAGE}" "-> Checking for Explorer image: ${C_BLUE}${EXPLORE_IMAGE}${C_RESET}..."
    if ! $SUDO_CMD docker image inspect "${EXPLORE_IMAGE}" &>/dev/null; then
        log "Explorer image not found, pulling..." "   -> Image not found locally. Pulling..."
        if ! execute_and_log $SUDO_CMD docker pull "${EXPLORE_IMAGE}"; then 
            log "ERROR: Failed to pull explorer image." "${C_RED}Error: Failed to pull ${EXPLORE_IMAGE}...${C_RESET}"
            return 1
        fi
    fi
    log "Explorer image OK." "-> Image OK.\n"
    return 0
}

run_in_volume() { local volume_name="$1"; shift; $SUDO_CMD docker run --rm -v "${volume_name}:/volume:ro" "${BACKUP_IMAGE}" "$@"; }

volume_checker_inspect() {
    local volume_name="$1"
    echo -e "\n${C_BLUE}--- Inspecting '${volume_name}' ---${C_RESET}"; $SUDO_CMD docker volume inspect "${volume_name}"
}

volume_checker_list_files() {
    local volume_name="$1"
    echo -e "\n${C_BLUE}--- Listing files in '${volume_name}' ---${C_RESET}"; run_in_volume "${volume_name}" ls -lah /volume
}

volume_checker_calculate_size() {
    local volume_name="$1"
    echo -e "\n${C_BLUE}--- Calculating total size of '${volume_name}' ---${C_RESET}"; run_in_volume "${volume_name}" du -sh /volume
}

volume_checker_explore() {
    local volume_name="$1"
    #  Ensures image exists before starting
    if ! ensure_explore_image; then return; fi

    clear
    echo -e "${C_RESET}=============================================="
    echo -e "          ${C_GREEN}Docker Tool Suite ${SCRIPT_VERSION}"
    echo -e "${C_RESET}=============================================="
    echo -e "${C_BLUE}           --- Interactive Shell ---${C_RESET}"
    echo -e "${C_RESET}----------------------------------------------\n"
    echo -e "${C_YELLOW}The volume ${C_BLUE}${volume_name} ${C_YELLOW}is mounted read-write at ${C_BLUE}/volume${C_YELLOW}."
    echo -e "${C_YELLOW}Type ${C_GREEN}'exit' ${C_YELLOW}or press ${C_GREEN}Ctrl+D ${C_YELLOW}to return.${C_RESET}\n"

    $SUDO_CMD docker run --rm -it \
        -e TERM="$TERM" \
        -v "${volume_name}:/volume" \
        -v /etc/localtime:/etc/localtime:ro \
        -w /volume \
        "${EXPLORE_IMAGE}" \
        bash -c "echo -e \"alias ll='ls -lah --color=auto'\" >> ~/.bashrc; \
                 echo -e \"export PS1='${C_RESET}[${C_GREEN}VOLUME-EXPLORER${C_RESET}@${C_BLUE}${volume_name}${C_RESET}:${C_GREEN}\w${C_RESET}] ${C_GREEN}# ${C_RESET}'\" >> ~/.bashrc; \
                 exec bash" || true
}

volume_checker_remove() {
    local volume_name="$1"
    read -rp "$(printf "\n${C_YELLOW}Permanently delete volume '${C_BLUE}%s${C_YELLOW}'? [y/N]: ${C_RESET}" "${volume_name}")" confirm
    if [[ "${confirm,,}" =~ ^(y|Y|yes|YES)$ ]]; then
        echo -e "-> Deleting volume '${volume_name}'..."
        if execute_and_log $SUDO_CMD docker volume rm "${volume_name}"; then echo -e "${C_GREEN}Volume successfully deleted.${C_RESET}"; sleep 2; return 0; else echo -e "${C_RED}Error: Failed to delete. It might be in use.${C_RESET}"; sleep 3; return 1; fi
    else echo -e "-> Deletion cancelled.${C_RESET}"; sleep 1; return 1; fi
}

volume_checker_menu() {
    local volume_name="$1"
    clear; volume_checker_inspect "${volume_name}"
    while true; do
        local options=(
            "${C_YELLOW}List volume files${C_RESET}"
            "${C_YELLOW}Calculate volume size${C_RESET}"
            "${C_BLUE}Explore volume in shell${C_RESET}"
            "${C_BOLD_RED}Remove volume${C_RESET}"
            "${C_GRAY}Return to volume list${C_RESET}"
            "${C_RED}Quit${C_RESET}"
        )
        PS3=$'\n'"${C_YELLOW}Enter action number: ${C_RESET}"; select action in "${options[@]}"; do
            case "$action" in
                "${C_YELLOW}List volume files${C_RESET}")
                    volume_checker_list_files "${volume_name}"
                    echo -e "\n${C_BLUE}Action complete. Press Enter to return to menu...${C_RESET}"; read -r
                    break
                    ;;
                "${C_YELLOW}Calculate volume size${C_RESET}")
                    volume_checker_calculate_size "${volume_name}"
                    echo -e "\n${C_BLUE}Action complete. Press Enter to return to menu...${C_RESET}"; read -r
                    break
                    ;;
                "${C_BLUE}Explore volume in shell${C_RESET}") volume_checker_explore "${volume_name}"; break ;;
                "${C_BOLD_RED}Remove volume${C_RESET}") if volume_checker_remove "${volume_name}"; then return; fi; break ;;
                "${C_GRAY}Return to volume list${C_RESET}") return ;;
                "${C_RED}Quit${C_RESET}") exit 0 ;;
                *) echo -e "${C_RED}Invalid option '$REPLY'${C_RESET}"; sleep 1; break ;;
            esac
        done
    done
}

volume_checker_main() {
    ensure_backup_image
    while true; do
        clear
        echo -e "${C_RESET}=============================================="
        echo -e "          ${C_GREEN}Docker Tool Suite ${SCRIPT_VERSION}"
        echo -e "${C_RESET}=============================================="
        echo -e "           ${C_BLUE}--- Inspect & Manage Volumes ---"
        echo -e "${C_RESET}----------------------------------------------\n"
        mapfile -t volumes < <($SUDO_CMD docker volume ls --format "{{.Name}}")
        if [ ${#volumes[@]} -eq 0 ]; then echo -e "${C_RED}No Docker volumes found.${C_RESET}"; sleep 2; return; fi
        echo -e "${C_BLUE}Volume list:${C_RESET}"
        PS3=$'\n'"${C_YELLOW}Enter ${C_BLUE}volume No${C_YELLOW}; ${C_GRAY}(r)eturn ${C_YELLOW}or ${C_RED}(q)uit${C_RESET}: "; select volume_name in "${volumes[@]}"; do
            if [[ "$REPLY" == "r" || "$REPLY" == "R" ]]; then return; fi
            if [[ "$REPLY" == "q" || "$REPLY" == "Q" ]]; then exit 0; fi
            if [[ -n "$volume_name" ]]; then volume_checker_menu "${volume_name}"; break; else echo -e "${C_RED}Invalid selection.${C_RESET}"; fi
        done
    done
}

_find_project_dir_by_name() {
    local project_name="$1"
    
    # Search in Essential Apps path
    if [ -d "$APPS_BASE_PATH/$project_name" ]; then
        if find_compose_file "$APPS_BASE_PATH/$project_name" &>/dev/null; then
            echo "$APPS_BASE_PATH/$project_name"
            return 0
        fi
    fi

    # Search in Managed Apps path
    local managed_path="$APPS_BASE_PATH/$MANAGED_SUBDIR"
    if [ -d "$managed_path/$project_name" ]; then
        if find_compose_file "$managed_path/$project_name" &>/dev/null; then
            echo "$managed_path/$project_name"
            return 0
        fi
    fi
    
    return 1 # Not found
}

volume_smart_backup_main() {
    clear; echo -e "${C_GREEN}Starting Smart Docker Volume Backup...${C_RESET}"; ensure_backup_image

    mapfile -t all_volumes < <($SUDO_CMD docker volume ls --format "{{.Name}}"); local -a filtered_volumes=()
    for volume in "${all_volumes[@]}"; do if [[ ! " ${IGNORED_VOLUMES[*]-} " =~ " ${volume} " ]]; then filtered_volumes+=("$volume"); fi; done
    if [[ ${#filtered_volumes[@]} -eq 0 ]]; then echo -e "${C_YELLOW}No available volumes to back up.${C_RESET}"; sleep 2; return; fi

    local -a selected_status=(); for ((i=0; i<${#filtered_volumes[@]}; i++)); do selected_status+=("true"); done
    if ! show_selection_menu "Select Volumes for SMART BACKUP" "backup" filtered_volumes selected_status; then echo -e "${C_RED}Backup canceled.${C_RESET}"; return; fi
    local selected_volumes=(); for i in "${!filtered_volumes[@]}"; do if ${selected_status[$i]}; then selected_volumes+=("${filtered_volumes[$i]}"); fi; done
    if [[ ${#selected_volumes[@]} -eq 0 ]]; then echo -e "\n${C_RED}No volumes selected! Exiting.${C_RESET}"; return; fi

    # --- Phase 1: Group selected volumes by the app that owns them ---
    echo -e "\n${C_YELLOW}Analyzing volumes and grouping them by application...${C_RESET}"
    declare -A app_volumes_map
    declare -A app_dir_map
    local -a standalone_volumes=()

    for volume in "${selected_volumes[@]}"; do
        local container_id
        container_id=$($SUDO_CMD docker ps -q --filter "volume=${volume}" | head -n 1)

        if [[ -n "$container_id" ]]; then
            local project_name
            project_name=$($SUDO_CMD docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$container_id")

            if [[ -n "$project_name" ]]; then
                app_volumes_map["$project_name"]+="${volume} "
                if [[ ! -v "app_dir_map[$project_name]" ]]; then
                    echo " -> Found application for volume '${volume}': ${C_BLUE}${project_name}${C_RESET}"
                    local found_dir
                    found_dir=$(_find_project_dir_by_name "$project_name")
                    if [[ -n "$found_dir" ]]; then
                        app_dir_map["$project_name"]="$found_dir"
                    else
                        log "ERROR: Could not find directory for project '$project_name'. Treating as standalone."
                        standalone_volumes+=("$volume")
                        unset 'app_volumes_map["$project_name"]'
                        continue
                    fi
                fi
            else
                echo -e " -> Volume '${C_BLUE}${volume}${C_RESET}' is non-compose. Backing up as standalone."
                standalone_volumes+=("$volume")
            fi
        else
            echo -e " -> Volume '${C_BLUE}${volume}${C_RESET}' is standalone."
            standalone_volumes+=("$volume")
        fi
    done

    local backup_dir="${BACKUP_LOCATION%/}/$(date +'%Y-%m-%d_%H-%M-%S')"; mkdir -p "$backup_dir"

    # --- Phase 2: Process App Backups ---
    if [ -n "${!app_volumes_map[*]}" ]; then
        echo -e "\n${C_GREEN}--- Processing Application-Linked Backups ---${C_RESET}"
        for app_name in "${!app_volumes_map[@]}"; do
            echo -e "\n${C_YELLOW}Processing app: ${C_BLUE}${app_name}${C_RESET}"
            local app_dir=${app_dir_map[$app_name]}
            _stop_app_task "$app_name" "$app_dir"
            local -a vols_to_backup; read -r -a vols_to_backup <<< "${app_volumes_map[$app_name]}"
            echo "   -> Backing up ${#vols_to_backup[@]} volume(s)..."
            for volume in "${vols_to_backup[@]}"; do
                echo "      - Backing up ${C_BLUE}${volume}${C_RESET}..."
                execute_and_log $SUDO_CMD docker run --rm -v "${volume}:/volume:ro" -v "${backup_dir}:/backup" "${BACKUP_IMAGE}" tar -C /volume --zstd -cvf "/backup/${volume}.tar.zst" .
            done
            _start_app_task "$app_name" "$app_dir"
            echo -e "${C_GREEN}Finished processing ${app_name}.${C_RESET}"
        done
    fi

    # --- Phase 3: Process Standalone Backups ---
    if [[ ${#standalone_volumes[@]} -gt 0 ]]; then
        echo -e "\n${C_GREEN}--- Processing Standalone Volume Backups ---${C_RESET}"
        for volume in "${standalone_volumes[@]}"; do
            echo -e "${C_YELLOW}Backing up standalone volume: ${C_BLUE}${volume}${C_RESET}..."
            execute_and_log $SUDO_CMD docker run --rm -v "${volume}:/volume:ro" -v "${backup_dir}:/backup" "${BACKUP_IMAGE}" tar -C /volume --zstd -cvf "/backup/${volume}.tar.zst" .
        done
    fi

    echo -e "\n${C_YELLOW}Changing ownership to '${CURRENT_USER}'...${C_RESET}"
    $SUDO_CMD chown -R "${CURRENT_USER}:${CURRENT_USER}" "$backup_dir"
    echo -e "\n${C_GREEN}${TICKMARK} Backup tasks completed successfully!${C_RESET}"

    # --- Phase 4: Create Secure RAR Archive ---
    local create_rar=""
    while true; do
        read -p $'\n'"${C_BLUE}Do you want to create a password-protected RAR archive of this backup? (Y/N): ${C_RESET}" create_rar
        case "${create_rar,,}" in
            y|Y|yes|YES) break ;;
            n|N|no|NO)  echo -e "${C_YELLOW}Skipping RAR archive creation.${C_RESET}"; return ;;
            *)     echo -e "${C_RED}Invalid input. Please enter Y/YES or N/NO.${C_RESET}" ;;
        esac
    done

    if ! command -v rar &>/dev/null; then echo -e "\n${C_BOLD_RED}Error: 'rar' command not found. Cannot create archive.${C_RESET}"; return 1; fi
    
    local archive_password=""
    local password_is_set=false

    # --- Password Selection Loop ---
    if [[ -n "${ENCRYPTED_RAR_PASSWORD-}" ]]; then
        echo -e "\n${C_BLUE}A default archive password is configured.${C_RESET}"
        while true; do
            read -p "Choose: ${C_BLUE}(U)se saved${C_RESET}, ${C_YELLOW}(E)nter new${C_RESET}, ${C_GRAY}(N)o password${C_RESET}, ${C_RED}(C)ancel${C_RESET}: " pass_choice
            case "${pass_choice,,}" in
                u|U|use|USE)
                    archive_password=$(decrypt_pass "${ENCRYPTED_RAR_PASSWORD}")
                    if [[ -z "$archive_password" ]]; then
                        echo -e "${C_BOLD_RED}Error: Decryption failed. Please enter manually.${C_RESET}"
                    else
                        echo -e "${C_BLUE}Using saved password.${C_RESET}"
                        password_is_set=true
                    fi
                    break
                    ;;
                e|E|enter|ENTER)
                    echo -e "${C_YELLOW}-> Enter a session-specific password.${C_RESET}"
                    break
                    ;;
                n|N|no|NO)
                    echo -e "${C_YELLOW}Creating archive with NO password.${C_RESET}"
                    archive_password=""
                    password_is_set=true
                    break
                    ;;
                c|C|cancel|CANCEL)
                    echo -e "${C_RED}Archive creation canceled.${C_RESET}"; return ;;
                *)
                    echo -e "${C_RED}Invalid choice. Try again.${C_RESET}" ;;
            esac
        done
    fi

    # Manual Password Entry Loop
    if ! $password_is_set; then
        while true; do
            read -sp "Enter password for the archive (leave blank for none): " rar_pass_1; echo
            if [[ -z "$rar_pass_1" ]]; then
                archive_password=""
                echo -e "${C_YELLOW}Proceeding without a password.${C_RESET}"
                break
            fi
            read -sp "Confirm password: " rar_pass_2; echo
            if [[ "$rar_pass_1" == "$rar_pass_2" ]]; then
                archive_password="${rar_pass_1}"
                break
            else
                echo -e "${C_RED}Passwords do not match. Please try again.${C_RESET}"
            fi
        done
    fi

    local archive_name="Apps-backup[$(date +'%d.%m.%Y')].rar"
    local archive_path="$(dirname "$backup_dir")/${archive_name}"
    
    # Check for .rar OR .part1.rar (split archive)
    if [[ -f "$archive_path" ]] || [[ -f "${archive_path%.rar}.part1.rar" ]]; then
        archive_name="Apps-backup[$(date +'%d.%m.%Y_%H-%M-%S')].rar"
        archive_path="$(dirname "$backup_dir")/${archive_name}"
    fi

    # --- Split Logic ---
    local rar_split_opt=""
    local total_size
    total_size=$(du -sb "$backup_dir" | awk '{print $1}')
    
    echo -e "\n${C_YELLOW}Backup size is $(numfmt --to=iec-i --suffix=B "$total_size"). Select splitting option:${C_RESET}"
    echo "  1) No splitting"
    echo "  2) Split at 4GB (FAT32 compatible)"
    echo "  3) Split at 8GB (DVD DL)"
    echo "  4) Custom size (MB or GB)"
    
    while true; do
        read -p "${C_YELLOW}Enter choice [${C_RESET}1${C_YELLOW}-${C_RESET}4${C_YELLOW}]: ${C_RESET}" split_choice
        case "$split_choice" in
            1) rar_split_opt=""; break ;;
            # Note: 'm' and 'M' in standard RAR command mean different things.
            # 'M' = 1,000,000 bytes (Decimal). 'm' = 1024*1024 bytes (Binary).
            # We use 'm' here to match what the OS displays.
            2) rar_split_opt="-v4095m"; echo -e "${C_BLUE}-> Splitting at 4GB (FAT32 safe).${C_RESET}"; break ;;
            3) rar_split_opt="-v8192m"; echo -e "${C_BLUE}-> Splitting at 8GB.${C_RESET}"; break ;;
            4) 
                read -p "${C_YELLOW}Enter size (e.g., ${C_RESET}500m ${C_YELLOW}or ${C_RESET}2g${C_YELLOW}): ${C_RESET}" custom_size
                if [[ "$custom_size" =~ ^[0-9]+[mMgG]$ ]]; then
                    # Force unit to lowercase (m/g) so rar uses binary calculation (1024 multiplier)
                    # This ensures '500m' results in 500 MiB (approx 524 MB decimal), 
                    # which matches "500 MB" in Windows Explorer.
                    local safe_size="${custom_size,,}"
                    rar_split_opt="-v${safe_size}"
                    echo -e "${C_BLUE}-> Splitting at ${C_GREEN}${safe_size}${C_BLUE} (Binary units).${C_RESET}"
                    break
                else
                    echo -e "${C_RED}Invalid format. Use numbers followed by M or G.${C_RESET}"
                fi
                ;;
            *) echo -e "${C_RED}Invalid option.${C_RESET}" ;;
        esac
    done

    echo -e "\n${C_YELLOW}Creating secure RAR archive: ${C_GREEN}${archive_path}${C_RESET}"
    echo -e "${C_GRAY}(Please wait, this may take time...)${C_RESET}"

    local rar_log; rar_log=$(mktemp)
    local rar_success=false

    local rar_cmd=(rar a -ep1)
    [[ -n "$rar_split_opt" ]] && rar_cmd+=("$rar_split_opt")
    # Added "-y" to assume Yes on all queries (prevents freezing on overwrite prompts)
    rar_cmd+=("-m${RAR_COMPRESSION_LEVEL:-3}" "-k" "-y")

    if [[ -n "$archive_password" ]]; then
        rar_cmd+=("-hp")
        rar_cmd+=(-- "${archive_path}" "${backup_dir}")
        if printf '%s' "$archive_password" | "${rar_cmd[@]}" &> "$rar_log"; then
            rar_success=true
        fi
    else
        rar_cmd+=(-- "${archive_path}" "${backup_dir}")
        if "${rar_cmd[@]}" &> "$rar_log"; then
            rar_success=true
        fi
    fi

    # --- Colorized Log Output ---
    while IFS= read -r line; do
        if [[ "$line" =~ (Done|OK|All OK) ]]; then
            echo -e "${C_GREEN}${line}${C_RESET}"
        elif [[ "$line" =~ (Adding|Updating|Creating) ]]; then
            echo -e "${C_BLUE}${line}${C_RESET}"
        elif [[ "$line" =~ (Error|WARNING|Cannot) ]]; then
            echo -e "${C_BOLD_RED}${line}${C_RESET}"
        elif [[ "$line" =~ [0-9]+% ]]; then
            echo -e "${line//%/%${C_RESET}}" 
        else
            echo "$line"
        fi
    done < "$rar_log"

    cat "$rar_log" >> "${LOG_FILE:-/dev/null}"
    rm "$rar_log"

    if $rar_success; then
        echo -e "\n${C_GREEN}RAR archive created successfully.${C_RESET}\n"

        # --- Handle Split Archives for Verification ---
        local file_to_verify="$archive_path"
        
        # If the standard .rar doesn't exist, check for a .part1.rar (split archive)
        if [[ ! -f "$file_to_verify" ]] && [[ -f "${archive_path%.rar}.part1.rar" ]]; then
            file_to_verify="${archive_path%.rar}.part1.rar"
            echo -e "${C_BLUE}Detected split archive. Verifying part 1 sequence...${C_RESET}"
        fi

        # --- Verify the archive integrity ---
        echo -e "${C_YELLOW}Verifying archive integrity...${C_RESET}"
        local verify_cmd=(rar t)
        [[ -n "$archive_password" ]] && verify_cmd+=("-p${archive_password}")

        # Use the corrected filename here
        verify_cmd+=("--" "$file_to_verify")
        if "${verify_cmd[@]}" &>/dev/null; then
             echo -e "${C_GREEN}Verification Passed: Archive is healthy.${C_RESET}\n"
        else
             echo -e "${C_BOLD_RED}Verification FAILED! Do not delete the source files.${C_RESET}\n"
             # This prevents the delete prompt from appearing if verification fails
             return 1
        fi


        while true; do
            echo -e "${C_YELLOW}Do you want to delete the source backup folder?${C_RESET}"
            echo -e "[${C_GREEN}${backup_dir}${C_RESET}]"
            read -rp "(${C_RED}y${C_RESET}/${C_GREEN}N${C_RESET}): " delete_source
            case "${delete_source,,}" in
                y|Y|yes|YES)
                    log "Deleting source folder: $backup_dir"
                    execute_and_log $SUDO_CMD rm -rf "${backup_dir}"
                    echo -e "\n${C_RED}Source folder deleted.${C_RESET}";
                    break ;;
                n|N|no|NO|"")
                    echo -e "\n${C_YELLOW}Source backup folder kept.${C_RESET}";
                    break ;;
                *) echo -e "${C_RED}Please answer ${C_YELLOW}y${C_RED}/${C_YELLOW}YES ${C_RED}or ${C_GREEN}N${C_RED}/${C_GREEN}NO${C_RED}.${C_RESET}" ;;
            esac
        done
    else
        echo -e "\n${C_BOLD_RED}Error: Failed to create RAR archive.${C_RESET}"
    fi
}

volume_restore_main() {
    clear; echo -e "${C_GREEN}Starting Docker Volume Restore...${C_RESET}"; ensure_backup_image
    
    mapfile -t backup_files < <(find "$RESTORE_LOCATION" -type f \( -name "*.tar.zst" -o -name "*.tar.gz" \) 2>/dev/null | sort)
    if [ ${#backup_files[@]} -eq 0 ]; then echo -e "${C_RED}No backup files (.tar.zst, .tar.gz) found in or under ${RESTORE_LOCATION}${C_RESET}"; sleep 3; return; fi
    
    local -a file_display_names=(); for file in "${backup_files[@]}"; do file_display_names+=("$(realpath --relative-to="$RESTORE_LOCATION" "$file")"); done
    
    local -a selected_status=(); for ((i=0; i<${#backup_files[@]}; i++)); do selected_status+=("false"); done
    if ! show_selection_menu "Select archives to RESTORE" "restore" file_display_names selected_status; then
        echo -e "${C_RED}Restore canceled.${C_RESET}"; return;
    fi

    local -a selected_files=(); for i in "${!backup_files[@]}"; do if ${selected_status[$i]}; then selected_files+=("${backup_files[$i]}"); fi; done

    if [[ ${#selected_files[@]} -eq 0 ]]; then
        echo -e "\n${C_YELLOW}No archives were selected. Restore operation cancelled.${C_RESET}"
        return
    fi
    
    echo -e "\n${C_RED}This will OVERWRITE existing data in corresponding volumes!${C_RESET}"; read -p "Are you sure? (y/N): " confirm
    if [[ ! "${confirm,,}" =~ ^(y|Y|yes|YES)$ ]]; then echo -e "${C_RED}Restore canceled.${C_RESET}"; return; fi
    
    for backup_file in "${selected_files[@]}"; do
        local base_name; base_name=$(basename "$backup_file"); local volume_name="${base_name%%.tar.*}"
        echo -e "\n${C_YELLOW}Restoring ${C_BLUE}${base_name}${C_RESET} to volume ${C_BLUE}${volume_name}${C_RESET}..."

        if ! $SUDO_CMD docker volume inspect "$volume_name" &>/dev/null; then
            echo "   -> Volume does not exist. Creating..."
            local compose_project="${volume_name%%_*}"
            local compose_volume="${volume_name#*_}"
            $SUDO_CMD docker volume create --label "com.docker.compose.project=${compose_project}" --label "com.docker.compose.volume=${compose_volume}" "$volume_name" >/dev/null
        fi

        echo "   -> Importing data..."
        local tar_opts="-xvf"; [[ "$base_name" == *.zst ]] && tar_opts="--zstd -xvf"
        execute_and_log $SUDO_CMD docker run --rm -v "${volume_name}:/target" -v "$(dirname "$backup_file"):/backup" "${BACKUP_IMAGE}" tar -C /target ${tar_opts} "/backup/${base_name}"
        echo -e "   ${C_GREEN}${TICKMARK} Restore for volume ${volume_name} completed.${C_RESET}"
    done
    echo -e "\n${C_GREEN}All selected restore tasks finished.${C_RESET}"
}

volume_manager_menu() {
    check_root
    local options=(
        "Smart Backup (Stop/Start Apps)"
        "Restore Volumes"
        "Inspect / Manage a Volume"
    )
    while true; do
        print_standard_menu "Volume Manager" options "RQ"
        read -rp "${C_YELLOW}Please select an option: ${C_RESET}" choice
        case "$choice" in
            1) 
                volume_smart_backup_main
                echo -e "\nPress Enter to return..."; read -r
                ;;
            2) 
                volume_restore_main
                echo -e "\nPress Enter to return..."; read -r
                ;;
            3) volume_checker_main ;;
            [rR]) return ;;
            [qQ]) log "Exiting script." "${C_GRAY}Exiting.${C_RESET}"; exit 0 ;;
            *) echo -e "\n${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
        esac
    done
}


# ======================================================================================
# --- SECTION 5: UTILITY MODULES ---
# ======================================================================================

system_prune_main() {
    check_root
    clear
    echo -e "${C_YELLOW}--- Docker System Prune ---${C_RESET}\n"
    echo -e "This will remove:"
    echo "  - all stopped containers"
    echo "  - all networks not used by at least one container"
    echo "  - all dangling images"
    echo "  - all build cache"
    echo ""
    read -rp "$(printf "${C_BOLD_RED}This action is IRREVERSIBLE. Are you sure? [y/N]: ${C_RESET}")" confirm
    if [[ "${confirm,,}" =~ ^(y|Y|yes|YES)$ ]]; then
        echo -e "\n${C_YELLOW}Pruning system...${C_RESET}"
        execute_and_log $SUDO_CMD docker system prune -af
        echo -e "\n${C_GREEN}${TICKMARK} System prune complete.${C_RESET}"
    else
        echo -e "\n${C_RED}Prune canceled.${C_RESET}"
    fi
}

prune_old_logs() {
    if [[ -n "${LOG_RETENTION_DAYS-}" && "$LOG_RETENTION_DAYS" -gt 0 ]]; then
        log "Checking for old log files to prune (older than $LOG_RETENTION_DAYS days)..."
        local deleted_count
        deleted_count=$(find "$LOG_DIR" -name "*.log" -type f -mtime +"$LOG_RETENTION_DAYS" -print | wc -l)
        if [[ "$deleted_count" -gt 0 ]]; then
            find "$LOG_DIR" -name "*.log" -type f -mtime +"$LOG_RETENTION_DAYS" -delete
            log "Pruned $deleted_count old log file(s)."
        fi
    fi
}

_log_viewer_select_and_view() {
    local less_prompt="(Scroll with arrow keys, press 'q' to return)"
    while true; do
        clear
        mapfile -t log_files < <(find "$LOG_DIR" -name "*.log" -type f | sort -r)

        if [ ${#log_files[@]} -eq 0 ]; then
            echo -e "${C_YELLOW}No log files found to view.${C_RESET}"; sleep 2; return
        fi

        clear
        echo -e "${C_RESET}=============================================="
        echo -e "          ${C_GREEN}Docker Tool Suite ${SCRIPT_VERSION}"
        echo -e "${C_RESET}=============================================="
        echo -e "           ${C_BLUE}--- Log Viewer ---"
        echo -e "${C_RESET}----------------------------------------------\n"
        echo -e "${C_YELLOW}Select a log file to view:${C_RESET}"
        
        local -a display_options=()
        for file in "${log_files[@]}"; do
            display_options+=("${C_GREEN}$(realpath --relative-to="$LOG_DIR" "$file")${C_RESET}")
        done
        display_options+=("${C_GRAY}Return to Log Manager${C_RESET}")
        
        PS3=$'\n'"${C_YELLOW}Enter your choice: ${C_RESET}"
        select choice in "${display_options[@]}"; do
            if [[ "$choice" == "${C_GRAY}Return to Log Manager${C_RESET}" ]]; then
                return
            elif [[ -n "$choice" ]]; then
                local idx=$((REPLY - 1))
                echo -e "${C_RESET}----------------------------------------------"
                echo -e "\n${C_BLUE}Opening log ${display_options[$idx]}"
                echo -e "${C_RESET}----------------------------------------------\n"
                echo -e "${C_GREEN}--- Log START ---${C_RESET}"
                less -RX --prompt="$less_prompt" "${log_files[$idx]}"
                break
            else
                echo -e "${C_RED}Invalid option. Please try again.${C_RESET}"; sleep 1; break
            fi
        done
    done
}

log_remover_main() {
    clear
    mapfile -t log_files < <(find "$LOG_DIR" -name "*.log" -type f | sort -r)
    if [ ${#log_files[@]} -eq 0 ]; then echo -e "${C_YELLOW}No log files found to delete.${C_RESET}"; sleep 2; return; fi

    local -a file_display_names=(); for file in "${log_files[@]}"; do file_display_names+=("$(realpath --relative-to="$LOG_DIR" "$file")"); done
    local -a selected_status=(); for ((i=0; i<${#log_files[@]}; i++)); do selected_status+=("false"); done

    if ! show_selection_menu "Select logs to DELETE" "delete" file_display_names selected_status; then
        echo -e "${C_YELLOW}Deletion canceled.${C_RESET}"; sleep 1; return
    fi
    
    local -a files_to_delete=()
    for i in "${!log_files[@]}"; do if ${selected_status[$i]}; then files_to_delete+=("${log_files[$i]}"); fi; done
    if [ ${#files_to_delete[@]} -eq 0 ]; then echo -e "\n${C_YELLOW}No logs selected.${C_RESET}"; sleep 1; return; fi

    echo -e "\n${C_BOLD_RED}You are about to permanently delete ${#files_to_delete[@]} log file(s).${C_RESET}"
    read -p "${C_YELLOW}Are you sure? [${C_RESET}Y${C_YELLOW}/${C_RESET}N${C_YELLOW}]: ${C_RESET}" confirm
    if [[ ! "${confirm,,}" =~ ^(y|Y|yes|YES)$ ]]; then echo -e "${C_RED}Deletion canceled.${C_RESET}"; sleep 1; return; fi
    
    echo ""
    for file in "${files_to_delete[@]}"; do
        if rm "$file"; then
            log "Deleted log file: $file" "-> Deleted ${C_BLUE}$(basename "$file")${C_RESET}"
        else
            log "ERROR: Failed to delete log file: $file" "-> ${C_RED}Failed to delete $(basename "$file")${C_RESET}"
        fi
    done
    echo -e "\n${C_GREEN}Deletion complete.${C_RESET}"
}

log_manager_menu() {
    local options=(
        "View Logs"
        "Delete Logs"
    )
    while true; do
        print_standard_menu "Log Manager" options "RQ"
        read -rp "${C_YELLOW}Please select an option: ${C_RESET}" choice
        case "$choice" in
            1) _log_viewer_select_and_view ;;
            2) log_remover_main; echo -e "\nPress Enter to return..."; read -r ;;
            [rR]) return ;;
            [qQ]) exit 0 ;;
            *) echo -e "\n${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
        esac
    done
}

update_secure_archive_settings() {
    check_root
    clear
    echo -e "${C_YELLOW}--- Update Secure Archive Password ---${C_RESET}\n"
    
    local rar_pass_1 rar_pass_2 ENCRYPTED_RAR_PASSWORD=""
    while true; do
        read -sp "Enter a new password (leave blank to remove, or type 'cancel' to exit): " rar_pass_1; echo
        
        if [[ "${rar_pass_1,,}" == "cancel" ]]; then
            echo -e "${C_YELLOW}Operation cancelled. No changes were made.${C_RESET}"
            return
        fi

        if [[ -z "$rar_pass_1" ]]; then
            # User wants to remove the password
            break
        fi
        read -sp "Confirm new password: " rar_pass_2; echo

        if [[ "$rar_pass_1" == "$rar_pass_2" ]]; then
            ENCRYPTED_RAR_PASSWORD=$(encrypt_pass "${rar_pass_1}")
            break
        else
            echo -e "${C_RED}Passwords do not match. Please try again.${C_RESET}"
        fi
    done

    echo -e "\n${C_YELLOW}Updating configuration file...${C_RESET}"
    # Use printf to create a safely quoted line for both replacement and appending.
    local new_config_line
    new_config_line=$(printf "ENCRYPTED_RAR_PASSWORD=%q" "${ENCRYPTED_RAR_PASSWORD}")

    # --- Robustly update the config file ---
    # 1. Delete any existing ENCRYPTED_RAR_PASSWORD lines to prevent duplicates and clean up.
    sed -i '/^ENCRYPTED_RAR_PASSWORD=/d' "$CONFIG_FILE"

    # 2. Insert the new line in the correct section for organization.
    #    This finds the anchor comment and adds the password line after it.
    local anchor="# RAR Password is encrypted using a machine-specific key."
    sed -i "\|$anchor|a ${new_config_line}" "$CONFIG_FILE"
    
    # Reload the config into the current script session
    source "$CONFIG_FILE"

    if [[ -z "$ENCRYPTED_RAR_PASSWORD" ]]; then
        echo -e "${C_GREEN}${TICKMARK} Default archive password has been removed.${C_RESET}"
    else
        echo -e "${C_GREEN}${TICKMARK} Archive password updated successfully.${C_RESET}"
    fi
}

# --- Unused Image Updater Function ---
update_unused_images_main() {
    check_root
    
    # Use the global IS_CRON_RUN variable instead of local logic.
    if [[ "$IS_CRON_RUN" == "false" ]]; then clear; fi
    
    log "Starting unused image update script." "${C_GREEN}--- Starting Unused Docker Image Updater ---${C_RESET}"
    if $DRY_RUN; then log "--- Starting in Dry Run mode. No changes will be made. ---" "${C_GRAY}[DRY RUN] No changes will be made.${C_RESET}"; fi

    # Convert IGNORED_IMAGES array to a grep pattern
    local ignored_pattern
    if [[ ${#IGNORED_IMAGES[@]} -gt 0 ]]; then
        ignored_pattern=$(IFS="|"; echo "${IGNORED_IMAGES[*]}")
    else
        ignored_pattern="^$" # A pattern that matches nothing
    fi

    local total_images_scanned=0 used_count=0 ignored_count=0 unpullable_count=0

    log "Finding images used by existing containers (running or stopped)..." "${C_GRAY} -> Finding images used by existing containers...${C_RESET}"
    local used_image_ids
    used_image_ids=$($SUDO_CMD docker ps -aq | xargs -r $SUDO_CMD docker inspect --format='{{.Image}}' | sed 's/sha256://' | cut -c1-12 | sort -u)

    local -a images_to_update=()
    log "Scanning all local images to find unused ones..." "${C_GRAY} -> Scanning all local images...${C_RESET}"
    
    while read -r image_id image_name; do
        total_images_scanned=$((total_images_scanned + 1))
        
        if echo "$used_image_ids" | grep -qx "$image_id"; then
            log "Skipping used image: $image_name (ID: $image_id)"
            used_count=$((used_count + 1))
            continue
        fi
        
        if [[ ${#IGNORED_IMAGES[@]} -gt 0 ]] && echo "$image_name" | grep -qE "$ignored_pattern"; then
            log "Skipping ignored image: $image_name"
            ignored_count=$((ignored_count + 1))
            continue
        fi

        if [[ "$image_name" == "<none>:<none>" ]]; then
            log "Skipping unpullable image: $image_name (ID: $image_id)"
            unpullable_count=$((unpullable_count + 1))
            continue
        fi
        
        images_to_update+=("$image_name")
    done < <($SUDO_CMD docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}')

    if [ ${#images_to_update[@]} -gt 0 ]; then
        log "Found ${#images_to_update[@]} unused images to update. Starting parallel pulls..." "${C_BLUE}Found ${#images_to_update[@]} images to update. Pulling...${C_RESET}"
        for image in "${images_to_update[@]}"; do
            (
                log "Updating unused image: $image"
                execute_and_log $SUDO_CMD docker pull "$image"
            ) &
        done
        wait # Wait for all background pull jobs to finish
        log "All image updates are complete." "${C_GREEN}All image pulls are complete.${C_RESET}"
    else
        log "No unused images found to update." "${C_YELLOW}No unused images found to update.${C_RESET}"
    fi

    local updated_count=${#images_to_update[@]}
    log "Cleaning up old, dangling images..." "${C_BLUE}Cleaning up old, dangling images...${C_RESET}"
    execute_and_log $SUDO_CMD docker image prune -f

    echo -e "\n${C_GREEN}--- Update Summary ---${C_RESET}"
    echo "  Total images scanned: ${C_BLUE}$total_images_scanned${C_RESET}"
    if $DRY_RUN; then echo "  Images that would be updated: ${C_BLUE}$updated_count${C_RESET}"; else echo "  Images updated: ${C_BLUE}$updated_count${C_RESET}"; fi
    echo "  Images skipped (in use): ${C_YELLOW}$used_count${C_RESET}"
    echo "  Images skipped (on ignore list): ${C_YELLOW}$ignored_count${C_RESET}"
    echo "  Images skipped (un-pullable): ${C_YELLOW}$unpullable_count${C_RESET}"
    log "--- Update Summary ---"; log "Total images scanned: $total_images_scanned"; log "Images updated/to be updated: $updated_count"; log "Images skipped (in use): $used_count"; log "Images skipped (on ignore list): $ignored_count"; log "Images skipped (un-pullable): $unpullable_count"; log "Script finished."
}

# --- Cron Job Setup for Unused Image Updater ---
setup_unused_images_cron_job() {
    check_root
    echo -e "\n${C_YELLOW}--- Schedule Automatic Unused Image Updates ---${C_RESET}"
    read -p "Would you like to schedule the unused image updater to run automatically? (Y/n): " schedule_now
    if [[ ! "$(echo "${schedule_now:-y}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|Y|yes|YES)$ ]]; then
        echo -e "${C_YELLOW}Skipping cron job setup.${C_RESET}"; return
    fi
    
    local cron_target_user="root"
    echo "The script needs Docker permissions to run. We recommend running the scheduled task as 'root'."
    read -p "Run the scheduled task as 'root'? (Y/n): " confirm_root
    if [[ ! "$(echo "${confirm_root:-y}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|Y|yes|YES)$ ]]; then
        echo -e "${C_YELLOW}Cron job setup canceled.${C_RESET}"; return
    fi

    local cron_schedule=""
    while true; do
        clear
        echo -e "${C_YELLOW}Choose a schedule for the unused image cleaner (for user: ${C_GREEN}$cron_target_user${C_YELLOW}):${C_RESET}\n"
        echo "   --- Daily & Weekly ---                  --- Monthly & Custom ---"
        echo "   1) Daily (at 3 AM)                      5) Bi-weekly (1st and 15th at 3 AM)"
        echo "   2) Every 3 days (at 3 AM)               6) Monthly (1st of month at 3 AM)"
        echo "   3) Weekly (Sunday at 3 AM)"
        echo "   4) Weekly (Saturday at 3 AM)            7) Custom"
        echo "                                           8) Cancel"
        echo
        read -p "Enter your choice [1-8]: " choice
        case $choice in
            1) cron_schedule="0 3 * * *"; break ;;
            2) cron_schedule="0 3 */3 * *"; break ;;
            3) cron_schedule="0 3 * * 0"; break ;;
            4) cron_schedule="0 3 * * 6"; break ;;
            5) cron_schedule="0 3 1,15 * *"; break ;;
            6) cron_schedule="0 3 1 * *"; break ;;
            7) read -p "Enter custom cron schedule (e.g., '0 5 * * *' for 5 AM daily): " custom_cron
               if [[ -n "$custom_cron" ]]; then cron_schedule="$custom_cron"; break; fi ;;
            8) echo -e "${C_YELLOW}Cron job setup canceled.${C_RESET}"; return ;;
            *) echo -e "${C_RED}Invalid option. Please try again.${C_RESET}"; sleep 1 ;;
        esac
    done

    echo -e "\n${C_YELLOW}Adding job to root's crontab...${C_RESET}"
    local cron_command="$cron_schedule $SUDO_CMD $SCRIPT_PATH update-unused --cron"
    local cron_comment="# Added by Docker Tool Suite to update unused Docker images"
    
    local current_crontab; current_crontab=$(crontab -u "$cron_target_user" -l 2>/dev/null || true)
    
    if echo "$current_crontab" | grep -Fq "update-unused"; then
        echo -e "${C_YELLOW}A cron job for this task already exists. Skipping.${C_RESET}"
    else
        local new_crontab
        new_crontab=$(printf "%s\n%s\n%s\n" "$current_crontab" "$cron_comment" "$cron_command")

        if ! echo "$new_crontab" | crontab -u "$cron_target_user" -; then
            echo -e "${C_RED}Error: Failed to install the cron job. The schedule '$cron_schedule' might be invalid.${C_RESET}"
            echo -e "${C_YELLOW}Crontab was not modified.${C_RESET}"
            return 1
        fi
        echo -e "${C_GREEN}${TICKMARK} Cron job added successfully!${C_RESET}"
    fi
}

utility_menu() {
    local options=(
        "Manage Settings"
        "Update all running Apps"
        "Update Unused Images"
        "Clean Up Docker System"
        "Log Manager"
    )
    while true; do
        print_standard_menu "Utilities" options "RQ"
        read -rp "${C_YELLOW}Please select an option: ${C_RESET}" choice
        case "$choice" in
            1) settings_manager_menu ;;
            2) app_manager_update_all_known_apps; echo -e "\nPress Enter to return..."; read -r ;;
            3) update_unused_images_main; echo -e "\nPress Enter to return..."; read -r ;;
            4) system_prune_main; echo -e "\nPress Enter to return..."; read -r ;;
            5) log_manager_menu ;;
            [rR]) return ;;
            [qQ]) log "Exiting script." "${C_GRAY}Exiting.${C_RESET}"; exit 0 ;;
            *) echo -e "\n${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
        esac
    done
}

_update_config_value() {
    local key="$1"
    local prompt_text="$2"
    local current_value="${3-}"
    local new_value

    read -p "$prompt_text [${C_GREEN}${current_value}${C_RESET}]: " new_value
    new_value=${new_value:-$current_value}

    # Use sed to replace the line in-place if it exists, otherwise append it.
    if grep -q "^${key}=" "$CONFIG_FILE"; then
        # Use a temporary variable to handle potential special characters for sed
        local replacement; replacement=$(printf "%q" "$new_value")
        sed -i "/^${key}=/c\\${key}=${replacement}" "$CONFIG_FILE"
    else
        echo "${key}=$(printf "%q" "$new_value")" >> "$CONFIG_FILE"
    fi
    
    echo -e "${C_GREEN}${TICKMARK} Setting '${key}' updated.${C_RESET}"
    # Reload the config into the current script session to reflect changes immediately
    source "$CONFIG_FILE"
}

update_ignored_items() {
    local item_type="$1" # "Volumes" or "Images"
    local -n source_items_ref="$2"
    local -n ignored_items_ref="$3"
    
    check_root
    
    # Combining the live list from Docker with the already configured ignored list.
    #    This ensures custom entries are preserved and displayed.
    local -a combined_list=("${source_items_ref[@]}" "${ignored_items_ref[@]}")
    mapfile -t all_available_items < <(printf "%s\n" "${combined_list[@]}" | sort -u)
    
    if [[ ${#all_available_items[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}No Docker ${item_type,,} found to configure.${C_RESET}"; sleep 2; return
    fi

    local -a selected_status=()
    # Check against the combined list
    for item in "${all_available_items[@]}"; do
        if [[ " ${ignored_items_ref[*]} " =~ " ${item} " ]]; then
            selected_status+=("true")
        else
            selected_status+=("false")
        fi
    done

    local -a new_ignored_list=()
    local title="Select ${item_type} to IGNORE"
    
    # Use the combined list for the menu
    if ! show_selection_menu "$title" "confirm" all_available_items selected_status; then
        echo -e "${C_YELLOW}Update cancelled.${C_RESET}"; return
    fi

    for i in "${!all_available_items[@]}"; do
        if ${selected_status[$i]}; then new_ignored_list+=("${all_available_items[$i]}"); fi
    done
    
    local config_key="IGNORED_${item_type^^}"
    local temp_file; temp_file=$(mktemp)

    # It finds the start of the block (e.g., "IGNORED_VOLUMES=(") and ignores lines until
    # it finds the closing parenthesis, without relying on fragile comments.
    awk -v key="$config_key" '
        $0 ~ "^" key "=\\(" { in_block = 1 }
        !in_block { print }
        in_block && /^\\)/ { in_block = 0 }
    ' "$CONFIG_FILE" > "$temp_file"
    mv "$temp_file" "$CONFIG_FILE"

    # Appending the newly generated block safely to the end of the file.
    {
        echo "# List of ${item_type,,} to ignore during operations."
        echo -n "${config_key}=("
        if [ ${#new_ignored_list[@]} -gt 0 ]; then
            printf "\n"
            for item in "${new_ignored_list[@]}"; do echo "    \"$item\""; done
        fi
        echo ")"
        echo
    } >> "$CONFIG_FILE"

    echo -e "${C_GREEN}${TICKMARK} Ignored ${item_type,,} list updated successfully.${C_RESET}"
    source "$CONFIG_FILE"
}

settings_manager_menu() {
    local options=(
        "Change Path Settings"
        "Change Helper Images"
        "Change Ignored Volumes"
        "Change Ignored Images"
        "Change Archive Settings"
        "Schedule Apps Updater"
        "Schedule Unused Image Updater"
    )
    while true; do
        print_standard_menu "Settings Manager" options "RQ"
        read -rp "${C_YELLOW}Please select an option: ${C_RESET}" choice
        
        case "$choice" in
            1) # Path Settings
                clear; echo -e "${C_YELLOW}--- Path Settings ---${C_RESET}"
                _update_config_value "APPS_BASE_PATH" "Base Compose Apps Path" "$APPS_BASE_PATH"
                _update_config_value "MANAGED_SUBDIR" "Managed Apps Subdirectory" "$MANAGED_SUBDIR"
                _update_config_value "BACKUP_LOCATION" "Default Backup Location" "$BACKUP_LOCATION"
                _update_config_value "RESTORE_LOCATION" "Default Restore Location" "$RESTORE_LOCATION"
                _update_config_value "LOG_DIR" "Log Directory Path" "$LOG_DIR"
                echo -e "\n${C_BLUE}Path settings updated. Press Enter...${C_RESET}"; read -r
                ;;
            2) # Helper Images
                clear; echo -e "${C_YELLOW}--- Helper Image Settings ---${C_RESET}"
                _update_config_value "BACKUP_IMAGE" "Backup Helper Image" "$BACKUP_IMAGE"
                _update_config_value "EXPLORE_IMAGE" "Volume Explorer Image" "$EXPLORE_IMAGE"
                echo -e "\n${C_BLUE}Image settings updated. Press Enter...${C_RESET}"; read -r
                ;;
            3) # Ignored Volumes
                local -a all_volumes; mapfile -t all_volumes < <($SUDO_CMD docker volume ls --format "{{.Name}}" | sort)
                update_ignored_items "Volumes" "all_volumes" "IGNORED_VOLUMES"
                echo -e "\nPress Enter to return..."; read -r
                ;;
            4) # Ignored Images
                local -a all_images; mapfile -t all_images < <($SUDO_CMD docker image ls --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>" | sort)
                update_ignored_items "Images" "all_images" "IGNORED_IMAGES"
                echo -e "\nPress Enter to return..."; read -r
                ;;
            5) # Archive Settings
                clear; echo -e "${C_YELLOW}--- Archive Settings ---${C_RESET}"
                
                update_secure_archive_settings
                _update_config_value "RAR_COMPRESSION_LEVEL" "Default RAR Compression Level (0-5)" "${RAR_COMPRESSION_LEVEL:-3}"

                echo -e "\n${C_BLUE}Archive settings updated. Press Enter...${C_RESET}"; read -r
                ;;
            6) # Schedule Apps Updater
                setup_cron_job
                echo -e "\nPress Enter to return..."; read -r
                ;;
            7) # Schedule Unused Image Updater
                setup_unused_images_cron_job
                echo -e "\nPress Enter to return..."; read -r
                ;;
            [rR]) return ;;
            [qQ]) log "Exiting script." "${C_GRAY}Exiting.${C_RESET}"; exit 0 ;;
            *) echo -e "\n${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
        esac
    done
}

# ======================================================================================
# --- SECTION 6: MAIN SCRIPT EXECUTION ---
# ======================================================================================

main_menu() {
    local options=(
        "Application Manager"
        "Volume Manager"
        "Utilities"
    )
    while true; do
        # Use "Q" mode to show only Quit, not Return
        print_standard_menu "Docker Tool Suite ${SCRIPT_VERSION} - ${C_BLUE}${CURRENT_USER}" options "Q"
        
        read -rp "${C_YELLOW}Please select an option: ${C_RESET}" choice
        case "$choice" in
            1) app_manager_menu ;;
            2) volume_manager_menu ;;
            3) utility_menu ;;
            [qQ]) log "Exiting script." "${C_GRAY}Exiting.${C_RESET}"; exit 0 ;;
            *) echo -e "\n${C_RED}Invalid option: '$choice'.${C_RESET}"; sleep 1 ;;
        esac
    done
}

# --- Argument Parsing at script entry ---
if [[ $# -gt 0 ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then echo -e "${C_RED}Config not found. Please run with 'sudo' for initial setup.${C_RESET}"; exit 1; fi
    source "$CONFIG_FILE"
    prune_old_logs
    case "$1" in
        update)
            shift
            if [[ "${1:-}" == "--cron" ]]; then
                IS_CRON_RUN=true
                # Check for a potential --dry-run flag after --cron, e.g., "update --cron --dry-run"
                [[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true
            else
                [[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
            fi
            app_manager_update_all_known_apps
            exit 0 ;;
        update-unused)
            shift # Move past 'update-unused'
            # Loop through remaining arguments
            while (( "$#" )); do
              case "$1" in
                --dry-run) DRY_RUN=true; shift ;;
                --cron) IS_CRON_RUN=true; shift ;;
                *) echo "Unknown option for update-unused: $1"; exit 1 ;;
              esac
            done
            update_unused_images_main
            exit 0 ;;
        *) echo "Unknown command: $1"; echo "Usage: $0 [update|update-unused|--help]"; exit 1 ;;
    esac
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    initial_setup
fi

source "$CONFIG_FILE"
LOG_FILE="$LOG_DIR/$(date +'%Y-%m-%d').log"; mkdir -p "$LOG_DIR"
prune_old_logs
check_deps
main_menu
