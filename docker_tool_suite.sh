#!/bin/bash
# ======================================================================================
# Docker Tool Suite v1.2
# ======================================================================================

# --- Strict Mode & Globals ---
set -euo pipefail
DRY_RUN=false

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

# --- User & Path Detection ---
if [[ -n "${SUDO_USER-}" ]]; then
    CURRENT_USER="${SUDO_USER}"
else
    CURRENT_USER="${USER:-$(whoami)}"
fi
SCRIPT_PATH=$(readlink -f "$0")

# --- MODIFIED: Command Prefix for Sudo ---
SUDO_CMD=""
if [[ $EUID -ne 0 ]]; then
    SUDO_CMD="sudo"
fi

# --- Unified Configuration Paths ---
CONFIG_DIR="/home/${CURRENT_USER}/.config/docker_tool_suite"
CONFIG_FILE="${CONFIG_DIR}/config.conf"

# --- Shared Helper Functions ---

# --- MODIFIED: check_root now authenticates on demand ---
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
    if [[ -n "${LOG_FILE-}" ]]; then echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; fi
    if [[ -n "${2-}" ]]; then echo -e "$2"; fi
}

execute_and_log() {
    "$@" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
    return "${PIPESTATUS[0]}"
}


check_deps() {
    log "Checking dependencies..." "${C_GRAY}Checking dependencies...${C_RESET}"
    local error_found=false
    # MODIFIED: Use $SUDO_CMD
    if ! command -v docker &>/dev/null; then log "Error: Docker not found." "${C_RED}Error: Docker is not installed...${C_RESET}"; error_found=true; fi
    if ! $SUDO_CMD docker compose version &>/dev/null; then log "Error: Docker Compose V2 not found." "${C_RED}Error: Docker Compose V2 not available...${C_RESET}"; error_found=true; fi
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
    for dir in "$path"/*; do if [ -d "$dir" ]; then app_array+=("$(basename "$dir")"); fi; done
    IFS=$'\n' app_array=($(sort <<<"${app_array[*]}")); unset IFS
}

show_selection_menu() {
    local title="$1" action_verb="$2"; local -n all_items_ref="$3"; local -n selected_status_ref="$4"
    local extra_options_key="${5:-}"; local extra_options_str=""
    [[ "$extra_options_key" == "update" ]] && extra_options_str=" (u)pdate,"
    while true; do
        clear
        echo -e "=====================================================\n ${C_GREEN}${title}${C_RESET}\n Use number to toggle, (a) to toggle all\n====================================================="
        for i in "${!all_items_ref[@]}"; do
            if ${selected_status_ref[$i]}; then echo -e " $((i+1)). ${C_GREEN}[x]${C_RESET} ${all_items_ref[$i]}"; else echo -e " $((i+1)). ${C_RED}[ ]${C_RESET} ${all_items_ref[$i]}"; fi
        done
        echo "-----------------------------------------------------"
        echo "Enter a number, (a)ll, (${action_verb:0:1}) to ${action_verb},${extra_options_str} or (q)uit."
        read -rp "Your choice: " choice
        case "$choice" in
            [sS] | [${action_verb:0:1}]) return 0 ;;
            [uU]) if [[ "$extra_options_key" == "update" ]]; then return 2; else echo -e "${C_RED}Invalid choice.${C_RESET}"; sleep 1; fi ;;
            [qQ]) return 1 ;;
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
    echo -e "${C_BLUE}###############################################${C_RESET}"
    echo -e "${C_BLUE}#   ${C_YELLOW}Welcome to the Docker Tool Suite Setup!   ${C_BLUE}#${C_RESET}"
    echo -e "${C_BLUE}###############################################${C_RESET}\n"
    echo "This one-time setup will configure all modules."
    echo -e "Settings will be saved to: ${C_GREEN}${CONFIG_FILE}${C_RESET}\n"

    local apps_path_def="/home/${CURRENT_USER}/apps"
    local managed_subdir_def="managed_stacks"
    local backup_path_def="/home/${CURRENT_USER}/backups/volume-backups"
    local restore_path_def="/home/${CURRENT_USER}/backups/restore-folder"
    local log_dir_def="/home/${CURRENT_USER}/logs/docker_tool_suite"
    
    echo -e "${C_YELLOW}--- Path Settings ---${C_RESET}"
    read -p "Base Compose Apps Path [${C_GREEN}${apps_path_def}${C_RESET}]: " apps_path; APPS_BASE_PATH=${apps_path:-$apps_path_def}
    read -p "Managed Apps Subdirectory [${C_GREEN}${managed_subdir_def}${C_RESET}]: " managed_subdir; MANAGED_SUBDIR=${managed_subdir:-$managed_subdir_def}
    read -p "Default Backup Location [${C_GREEN}${backup_path_def}${C_RESET}]: " backup_loc; BACKUP_LOCATION=${backup_loc:-$backup_path_def}
    read -p "Default Restore Location [${C_GREEN}${restore_path_def}${C_RESET}]: " restore_loc; RESTORE_LOCATION=${restore_loc:-$restore_path_def}
    read -p "Log Directory Path [${C_GREEN}${log_dir_def}${C_RESET}]: " log_dir; LOG_DIR=${log_dir:-$log_dir_def}
    
    local -a selected_ignored_volumes=()
    read -p $'\n'"Do you want to configure ignored volumes now? (y/N): " config_vols
    if [[ "${config_vols,,}" =~ ^(y|yes)$ ]]; then
        mapfile -t all_volumes < <(docker volume ls --format "{{.Name}}" | sort)
        interactive_list_builder "Select Volumes to IGNORE during backup" all_volumes selected_ignored_volumes
    fi
    
    # --- BEGIN: Added Ignored Images Configuration ---
    local -a selected_ignored_images=()
    read -p $'\n'"Do you want to configure ignored images now? (y/N): " config_imgs
    if [[ "${config_imgs,,}" =~ ^(y|yes)$ ]]; then
        mapfile -t all_images < <(docker image ls --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>" | sort)
        interactive_list_builder "Select Images to IGNORE during updates" all_images selected_ignored_images
    fi
    # --- END: Added Ignored Images Configuration ---

    echo -e "\n${C_YELLOW}--- Secure Archive Settings (Optional) ---${C_RESET}"
    read -sp "Enter a default password for RAR archives (leave blank for none): " rar_pass; echo
    RAR_PASSWORD=${rar_pass}
    read -p "Default RAR Compression Level (0-5) [${C_GREEN}3${C_RESET}]: " rar_level
    RAR_COMPRESSION_LEVEL=${rar_level:-3}
    read -p "Delete original backup folder after creating RAR archive? (y/N): " rar_delete_src
    RAR_DELETE_SOURCE_AFTER=$([[ "${rar_delete_src,,}" =~ ^(y|yes)$ ]] && echo "true" || echo "false")

    clear
    echo -e "\n${C_GREEN}_--| Docker Tool Suite Setup |---_${C_RESET}\n"
    echo -e "${C_YELLOW}--- Configuration Summary ---${C_RESET}"
    echo "  App Manager:"
    echo -e "    Base Path:       ${C_GREEN}${APPS_BASE_PATH}${C_RESET}"
    echo -e "    Managed Subdir:  ${C_GREEN}${MANAGED_SUBDIR}${C_RESET}"
    echo "  Volume Manager:"
    echo -e "    Backup Path:     ${C_GREEN}${BACKUP_LOCATION}${C_RESET}"
    echo -e "    Restore Path:    ${C_GREEN}${RESTORE_LOCATION}${C_RESET}"
    echo "  Archive Settings:"
    echo -e "    RAR Level:       ${C_GREEN}${RAR_COMPRESSION_LEVEL}${C_RESET}"
    echo -e "    Delete Source:   ${C_GREEN}${RAR_DELETE_SOURCE_AFTER}${C_RESET}"
    echo "  General:"
    echo -e "    Log Path:        ${C_GREEN}${LOG_DIR}${C_RESET}\n"
    
    read -p "Save this configuration? (Y/n): " confirm_setup
    if [[ ! "${confirm_setup,,}" =~ ^(y|yes)$ ]]; then echo -e "\n${C_RED}Setup canceled.${C_RESET}"; exit 0; fi

    echo -e "\n${C_GREEN}Saving configuration...${C_RESET}"; mkdir -p "${CONFIG_DIR}"
    {
        echo "# --- Unified Configuration for Docker Tool Suite ---"
        echo
        echo "# --- App Manager ---"
        echo "APPS_BASE_PATH=\"${APPS_BASE_PATH}\""
        echo "MANAGED_SUBDIR=\"${MANAGED_SUBDIR}\""
        echo
        echo "# --- Volume Manager ---"
        echo "BACKUP_LOCATION=\"${BACKUP_LOCATION}\""
        echo "RESTORE_LOCATION=\"${RESTORE_LOCATION}\""
        echo "BACKUP_IMAGE=\"docker/alpine-tar-zstd:latest\""
        echo "# List of volumes to ignore during backup."
        echo -n "IGNORED_VOLUMES=("
        if [ ${#selected_ignored_volumes[@]} -gt 0 ]; then
            printf "\n"; for vol in "${selected_ignored_volumes[@]}"; do echo "    \"$vol\""; done
        else
            printf "\n"; echo "    \"example-of-ignored_volume-1\""
        fi
        echo ")"
        # --- BEGIN: Save Ignored Images to config ---
        echo
        echo "# List of images to ignore during updates (e.g., custom builds or pinned versions)."
        echo -n "IGNORED_IMAGES=("
        if [ ${#selected_ignored_images[@]} -gt 0 ]; then
            printf "\n"; for img in "${selected_ignored_images[@]}"; do echo "    \"$img\""; done
        else
            printf "\n"; echo "    \"custom-registry/my-custom-app:latest\""
        fi
        echo ")"
        # --- END: Save Ignored Images to config ---
        echo
        echo "# --- Secure Archive (RAR) ---"
        printf "RAR_PASSWORD=%q\n" "${RAR_PASSWORD}"
        echo "RAR_COMPRESSION_LEVEL=${RAR_COMPRESSION_LEVEL}"
        echo "RAR_DELETE_SOURCE_AFTER=${RAR_DELETE_SOURCE_AFTER}"
        echo
        echo "# --- General ---"
        echo "LOG_DIR=\"${LOG_DIR}\""
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
    if [[ ! "$(echo "${schedule_now:-y}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|yes)$ ]]; then
        echo -e "${C_YELLOW}Skipping cron job setup.${C_RESET}"; return
    fi
    
    local cron_target_user="root"
    echo "The script needs Docker permissions to run. We recommend running the scheduled task as 'root'."
    read -p "Run the scheduled task as 'root'? (Y/n): " confirm_root
    if [[ ! "$(echo "${confirm_root:-y}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|yes)$ ]]; then
        echo -e "${C_YELLOW}Cron job setup canceled.${C_RESET}"; return
    fi

    local cron_schedule=""
    while true; do
        clear; echo -e "${C_YELLOW}Choose a schedule for the app updater (for user: ${C_GREEN}$cron_target_user${C_YELLOW}):${C_RESET}\n"
        echo "   1) Every day (at midnight)      3) Weekly (Sunday at midnight)"
        echo "   2) Every 3 days                 4) Custom"
        echo "   5) Cancel"
        read -p "Enter your choice [1-5]: " choice
        case $choice in
            1) cron_schedule="0 0 * * *"; break ;;
            2) cron_schedule="0 0 */3 * *"; break ;;
            3) cron_schedule="0 0 * * 0"; break ;;
            4) 
               read -p "Enter custom cron schedule (e.g., '0 */6 * * *' for every 6 hours): " custom_cron
               if [[ -n "$custom_cron" ]]; then cron_schedule="$custom_cron"; break; fi ;;
            5) echo -e "${C_YELLOW}Cron job setup canceled.${C_RESET}"; return ;;
            *) echo -e "${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
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
    log "Starting $app_name..."
    local compose_file; compose_file=$(find_compose_file "$app_dir")
    if [ -z "$compose_file" ]; then log "Warning: No compose file for '$app_name'. Skipping." ""; return; fi
    
    log "Pulling images for '$app_name'..."
    if execute_and_log $SUDO_CMD docker compose -f "$compose_file" pull; then
        log "Starting containers for '$app_name'..."
        execute_and_log $SUDO_CMD docker compose -f "$compose_file" up -d
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
    log "Updating $app_name..."
    local compose_file; compose_file=$(find_compose_file "$app_dir")
    if [ -z "$compose_file" ]; then log "Warning: No compose file for '$app_name'. Skipping." ""; return; fi
    
    local was_running=false
    if $SUDO_CMD docker compose -f "$compose_file" ps --status=running | grep -q 'running'; then
        was_running=true
    fi

    # --- BEGIN: Reworked image pull logic to handle ignored images ---
    log "Checking for images to update for '$app_name'..."
    mapfile -t all_app_images < <($SUDO_CMD docker compose -f "$compose_file" config --images 2>/dev/null)
    
    local -a images_to_pull=()
    local all_pulls_succeeded=true

    if [ ${#all_app_images[@]} -eq 0 ]; then
        log "No images defined in compose file for $app_name. Nothing to pull."
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
                log "Pulling image: $image" "   -> Pulling ${C_BLUE}${image}${C_RESET}..."
                if ! execute_and_log $SUDO_CMD docker pull "$image"; then
                    log "ERROR: Failed to pull image $image" "${C_BOLD_RED}Failed to pull ${image}. Check log for details.${C_RESET}"
                    all_pulls_succeeded=false
                fi
            done
        else
            log "All images for '$app_name' are on the ignore list. No images to pull." "All images for '${app_name}' are on the ignore list. Nothing to pull."
        fi
    fi

    if $all_pulls_succeeded; then
        log "Image update check successful for $app_name."
        if $was_running; then
            log "Restarting running application '$app_name' to apply any updates..."
            execute_and_log $SUDO_CMD docker compose -f "$compose_file" up -d --remove-orphans
            log "Successfully updated and restarted '$app_name'."
        else
            log "Application '$app_name' was not running. Images updated, but app remains stopped."
        fi
    else
        log "ERROR: Failed to pull one or more images for '$app_name'. Aborting update to prevent issues."
        echo -e "${C_BOLD_RED}Update for '$app_name' aborted due to pull failures. The application was not restarted.${C_RESET}"
    fi
    # --- END: Reworked image pull logic ---
}

app_manager_status() {
    clear; log "Generating App Status Overview" "${C_BLUE}Displaying App Status Overview...${C_RESET}"
    local less_prompt="(Scroll with arrow keys, press 'q' to return)"
    (
        declare -A running_projects
        while read -r proj; do [[ -n "$proj" ]] && running_projects["$proj"]=1; done < <($SUDO_CMD docker compose ls --quiet)
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
    ) | less -RFX --prompt="$less_prompt"
}

app_manager_interactive_handler() {
    local app_type_name="$1"
    local discovery_path="$2"
    local base_path="$3"

    while true; do
        clear
        echo -e "==============================================\n   ${C_GREEN}Manage ${app_type_name} Apps${C_RESET}\n=============================================="
        echo -e " ${C_YELLOW}1)${C_RESET} Start ${app_type_name} Apps"
        echo -e " ${C_YELLOW}2)${C_RESET} Stop ${app_type_name} Apps"
        echo -e " ${C_YELLOW}3)${C_RESET} Update ${app_type_name} Apps"
        echo -e " ${C_YELLOW}4)${C_RESET} Return to App Manager Menu"
        echo "----------------------------------------------"
        read -rp "Please select an option: " choice

        local action=""
        local title=""
        local task_func=""
        local menu_action_key=""

        case "$choice" in
            1)
                action="start"; title="Select ${app_type_name} Apps to START"; task_func="_start_app_task"; menu_action_key="start" ;;
            2)
                action="stop"; title="Select ${app_type_name} Apps to STOP"; task_func="_stop_app_task"; menu_action_key="stop" ;;
            3)
                action="update"; title="Select ${app_type_name} Apps to UPDATE"; task_func="_update_app_task"; menu_action_key="update" ;;
            4) return ;;
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
            title+=" (defaults to running)"
            declare -A running_apps_map
            while read -r project; do [[ -n "$project" ]] && running_apps_map["$project"]=1; done < <($SUDO_CMD docker compose ls --quiet)
            for app in "${all_apps[@]}"; do
                if [[ -v running_apps_map[$app] ]]; then selected_status+=("true"); else selected_status+=("false"); fi
            done
        else
            for ((i=0; i<${#all_apps[@]}; i++)); do selected_status+=("true"); done
        fi

        local menu_result; show_selection_menu "$title" "$menu_action_key" all_apps selected_status
        menu_result=$?

        if [[ $menu_result -eq 1 ]]; then log "User quit. No action taken." ""; continue; fi
        
        log "Performing '$action' on selected ${app_type_name} apps" "${C_GREEN}Processing selected apps...${C_RESET}\n"
        for i in "${!all_apps[@]}"; do
            if ${selected_status[$i]}; then $task_func "${all_apps[$i]}" "$base_path/${all_apps[$i]}"; fi
        done
        log "All selected ${app_type_name} app processes for '$action' finished."
        echo -e "\n${C_BLUE}Task complete. Press Enter...${C_RESET}"; read -r
    done
}

app_manager_update_all_known_apps() {
    check_root
    log "Starting update for all KNOWN applications..."
    
    local -a essential_apps; discover_apps "$APPS_BASE_PATH" essential_apps
    local -a managed_apps; discover_apps "$APPS_BASE_PATH/$MANAGED_SUBDIR" managed_apps

    if [ ${#essential_apps[@]} -eq 0 ] && [ ${#managed_apps[@]} -eq 0 ]; then
        log "No applications found in any directory." "${C_YELLOW}No applications found to update.${C_RESET}"
        return
    fi
    
    log "Found essential and managed apps. Starting update process..." "${C_GREEN}Updating all known applications...${C_RESET}"

    for app in "${essential_apps[@]}"; do
        if [[ "$app" != "$MANAGED_SUBDIR" ]]; then
            echo -e "\n${C_BLUE}--- Updating Essential App: ${C_YELLOW}${app}${C_BLUE} ---${C_RESET}"
            _update_app_task "$app" "$APPS_BASE_PATH/$app"
        fi
    done

    for app in "${managed_apps[@]}"; do
        echo -e "\n${C_BLUE}--- Updating Managed App: ${C_YELLOW}${app}${C_BLUE} ---${C_RESET}"
        _update_app_task "$app" "$APPS_BASE_PATH/$MANAGED_SUBDIR/$app"
    done

    log "Finished update task for all known applications." "${C_GREEN}\nFull update task finished.${C_RESET}"
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
        "Manage ESSENTIAL Apps"
        "Manage MANAGED Apps"
        "STOP ALL RUNNING APPS"
        "Return to Main Menu"
    )
    while true; do
        clear
        echo -e "==============================================\n   ${C_GREEN}Application Manager${C_RESET}\n=============================================="
        for i in "${!options[@]}"; do echo -e " ${C_YELLOW}$((i+1)))${C_RESET} ${options[$i]}"; done
        echo "----------------------------------------------"
        read -rp "Please select an option: " choice
        case "$choice" in
            1) app_manager_status ;;
            2) app_manager_interactive_handler "Essential" "$APPS_BASE_PATH" "$APPS_BASE_PATH" ;;
            3) app_manager_interactive_handler "Managed" "$APPS_BASE_PATH/$MANAGED_SUBDIR" "$APPS_BASE_PATH/$MANAGED_SUBDIR" ;;
            4) app_manager_stop_all; echo -e "\n${C_BLUE}Task complete. Press Enter...${C_RESET}"; read -r ;;
            5) return ;;
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

run_in_volume() { local volume_name="$1"; shift; $SUDO_CMD docker run --rm -v "${volume_name}:/volume:ro" "${BACKUP_IMAGE}" "$@"; }

volume_checker_inspect() {
    local volume_name="$1"
    echo -e "\n${C_BLUE}--- Inspecting '${volume_name}' ---${C_RESET}"; $SUDO_CMD docker volume inspect "${volume_name}"
    echo -e "\n${C_BLUE}--- Listing files in '${volume_name}' ---${C_RESET}"; run_in_volume "${volume_name}" ls -lah /volume
    echo -e "\n${C_BLUE}--- Calculating total size of '${volume_name}' ---${C_RESET}"; run_in_volume "${volume_name}" du -sh /volume
    echo -e "\n${C_BLUE}--- Top 10 largest files/folders in '${volume_name}' ---${C_RESET}"; run_in_volume "${volume_name}" sh -c 'du -ah /volume | sort -hr | head -n 10'
}

volume_checker_explore() {
    local volume_name="$1"
    echo -e "\n${C_BLUE}--- Interactive Shell for '${volume_name}' ---${C_RESET}"
    echo -e "${C_YELLOW}The volume is mounted read-write at /volume.\nType 'exit' or press Ctrl+D to return.${C_RESET}"
    $SUDO_CMD docker run --rm -it -v "${volume_name}:/volume" -w /volume "${BACKUP_IMAGE}" sh
}

volume_checker_remove() {
    local volume_name="$1"
    read -r -p "$(printf "\n${C_YELLOW}Permanently delete volume '${C_BLUE}%s${C_YELLOW}'? [y/N]: ${C_RESET}" "${volume_name}")" confirm
    if [[ "${confirm,,}" =~ ^(y|yes)$ ]]; then
        echo -e "-> Deleting volume '${volume_name}'..."
        if execute_and_log $SUDO_CMD docker volume rm "${volume_name}"; then echo -e "${C_GREEN}Volume successfully deleted.${C_RESET}"; sleep 2; return 0; else echo -e "${C_RED}Error: Failed to delete. It might be in use.${C_RESET}"; sleep 3; return 1; fi
    else echo -e "-> Deletion cancelled.${C_RESET}"; sleep 1; return 1; fi
}

volume_checker_menu() {
    local volume_name="$1"
    while true; do
        clear; volume_checker_inspect "${volume_name}"
        echo -e "\n${C_BLUE}--- Actions for '${volume_name}' ---${C_RESET}"
        local options=("Return to volume list" "Explore volume (interactive shell)" "Remove volume" "Quit")
        PS3=$'\n'"Enter action number: "; select action in "${options[@]}"; do
            case "$action" in
                "Return to volume list") return ;;
                "Explore volume (interactive shell)") volume_checker_explore "${volume_name}"; break ;;
                "Remove volume") if volume_checker_remove "${volume_name}"; then return; fi; break ;;
                "Quit") exit 0 ;;
                *) echo -e "${C_RED}Invalid option '$REPLY'${C_RESET}"; sleep 1; break ;;
            esac
        done
    done
}

volume_checker_main() {
    ensure_backup_image
    while true; do
        clear; echo -e "${C_GREEN}_--| Inspect & Manage Volumes |---_${C_RESET}"
        mapfile -t volumes < <($SUDO_CMD docker volume ls --format "{{.Name}}")
        if [ ${#volumes[@]} -eq 0 ]; then echo -e "${C_YELLOW}No Docker volumes found.${C_RESET}"; sleep 2; return; fi
        echo -e "\n${C_YELLOW}Please select a volume to manage:${C_RESET}"
        PS3=$'\n'"Enter number (or q to return): "; select volume_name in "${volumes[@]}"; do
            if [[ "$REPLY" == "q" ]]; then return; fi
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
    local processed_volumes_str=" "

    for volume in "${selected_volumes[@]}"; do
        local container_id; container_id=$($SUDO_CMD docker ps -q --filter "volume=${volume}" | head -n 1)
        if [[ -z "$container_id" ]]; then
            standalone_volumes+=("$volume")
            continue
        fi

        local project_name; project_name=$($SUDO_CMD docker inspect "$container_id" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)
        if [[ -n "$project_name" ]]; then
            # Add all volumes used by this project to its group
            local project_dir; project_dir=$(_find_project_dir_by_name "$project_name")
            if [[ -n "$project_dir" && ! -v "app_dir_map[$project_name]" ]]; then
                app_dir_map["$project_name"]="$project_dir"
                echo " -> Found application: ${C_BLUE}${project_name}${C_RESET}"
            fi

            mapfile -t all_vols_for_project < <($SUDO_CMD docker compose -p "$project_name" ps -q | xargs -r $SUDO_CMD docker inspect --format '{{range .Mounts}}{{.Name}} {{end}}' | tr ' ' '\n' | sort -u)
            
            for proj_vol in "${all_vols_for_project[@]}"; do
                if [[ " ${selected_volumes[*]} " =~ " ${proj_vol} " && ! " ${processed_volumes_str} " =~ " ${proj_vol} " ]]; then
                    app_volumes_map["$project_name"]+="${proj_vol} "
                    processed_volumes_str+="${proj_vol} "
                fi
            done
        else
            standalone_volumes+=("$volume")
        fi
    done
    
    # Finalize standalone volumes list
    local final_standalone=()
    for vol in "${standalone_volumes[@]}"; do
        if [[ ! " ${processed_volumes_str} " =~ " ${vol} " ]]; then
             final_standalone+=("$vol")
             processed_volumes_str+="${vol} "
        fi
    done
    standalone_volumes=("${final_standalone[@]}")

    local backup_dir="${BACKUP_LOCATION%/}/$(date +'%Y-%m-%d_%H-%M-%S')"; mkdir -p "$backup_dir"

    # --- Phase 2: Process backups on a per-app basis ---
    if [ ${#app_volumes_map[@]} -gt 0 ]; then
        echo -e "\n${C_GREEN}--- Processing Application-Linked Backups ---${C_RESET}"
        for app_name in "${!app_volumes_map[@]}"; do
            echo -e "\n${C_YELLOW}Processing app: ${C_BLUE}${app_name}${C_RESET}"
            
            local app_dir=${app_dir_map[$app_name]}
            
            # 1. Stop the app
            _stop_app_task "$app_name" "$app_dir"
            
            # 2. Backup its volumes
            local -a vols_to_backup; read -r -a vols_to_backup <<< "${app_volumes_map[$app_name]}"
            echo "   -> Backing up ${#vols_to_backup[@]} volume(s) for this app..."
            for volume in "${vols_to_backup[@]}"; do
                echo "      - Backing up ${C_BLUE}${volume}${C_RESET}..."
                execute_and_log $SUDO_CMD docker run --rm -v "${volume}:/volume:ro" -v "${backup_dir}:/backup" "${BACKUP_IMAGE}" tar -C /volume --zstd -cvf "/backup/${volume}.tar.zst" .
            done

            # 3. Start the app
            _start_app_task "$app_name" "$app_dir"
            echo -e "${C_GREEN}Finished processing ${app_name}.${C_RESET}"
        done
    fi

    # --- Phase 3: Process standalone volumes ---
    if [ ${#standalone_volumes[@]} -gt 0 ]; then
        echo -e "\n${C_GREEN}--- Processing Standalone Volume Backups ---${C_RESET}"
        for volume in "${standalone_volumes[@]}"; do
            echo -e "${C_YELLOW}Backing up standalone volume: ${C_BLUE}${volume}${C_RESET}..."
            execute_and_log $SUDO_CMD docker run --rm -v "${volume}:/volume:ro" -v "${backup_dir}:/backup" "${BACKUP_IMAGE}" tar -C /volume --zstd -cvf "/backup/${volume}.tar.zst" .
        done
    fi

    echo -e "\n${C_YELLOW}Changing ownership of all backup files to user '${CURRENT_USER}'...${C_RESET}"
    $SUDO_CMD chown -R "${CURRENT_USER}:${CURRENT_USER}" "$backup_dir"
    echo -e "\n${C_GREEN}${TICKMARK} All backup tasks completed successfully!${C_RESET}"

    # --- Phase 4: Create Secure RAR Archive (unchanged) ---
    read -p $'\n'"Do you want to create a single, password-protected RAR archive from this backup? (Y/n): " create_rar
    if [[ ! "$(echo "${create_rar:-y}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|yes)$ ]]; then
        echo -e "${C_YELLOW}Skipping RAR archive creation.${C_RESET}"; return
    fi
    if ! command -v rar &>/dev/null; then echo -e "\n${C_BOLD_RED}Error: 'rar' command not found...${C_RESET}"; return 1; fi
    local archive_password="${RAR_PASSWORD-}"; if [[ -z "$archive_password" ]]; then read -sp "Enter password for the archive: " archive_password; echo; fi
    if [[ -z "$archive_password" ]]; then echo -e "${C_RED}No password provided. Aborting.${C_RESET}"; return; fi
    local archive_name="Apps-backup[$(date +'%d.%m.%Y')].rar"; local archive_path="$(dirname "$backup_dir")/${archive_name}"
    local rar_split_opt=""; local total_size; total_size=$(du -sb "$backup_dir" | awk '{print $1}'); local eight_gb=$((8 * 1024 * 1024 * 1024))
    if (( total_size > eight_gb )); then
        read -p "Backup size is over 8GB. Split archive into 8GB parts? (Y/n): " confirm_split
        if [[ "$(echo "${confirm_split:-y}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|yes)$ ]]; then rar_split_opt="-v8g"; fi
    fi
    echo -e "\n${C_YELLOW}Creating secure RAR archive: ${C_GREEN}${archive_path}${C_RESET}"; echo -e "${C_GRAY}(This may take some time...)${C_RESET}"
    if execute_and_log rar a -ep1 ${rar_split_opt} "-m${RAR_COMPRESSION_LEVEL:-3}" "-hp${archive_password}" -- "${archive_path}" "${backup_dir}"; then
        echo -e "${C_GREEN}${TICKMARK} Secure archive created successfully.${C_RESET}"; $SUDO_CMD chown "${CURRENT_USER}:${CURRENT_USER}" "${archive_path}"*
        local should_delete_source=${RAR_DELETE_SOURCE_AFTER:-false}; local prompt_text="Delete the original backup folder ('${backup_dir}')?"; local prompt_opts=$([[ "$should_delete_source" == "true" ]] && echo "Y/n" || echo "y/N"); read -p "${prompt_text} [${prompt_opts}]: " confirm_del
        local final_decision=false; if [[ "${confirm_del,,}" == "y" ]] || [[ "${confirm_del,,}" == "yes" ]]; then final_decision=true; elif [[ -z "$confirm_del" && "$should_delete_source" == "true" ]]; then final_decision=true; fi
        if $final_decision; then echo -e "${C_YELLOW}Deleting source folder...${C_RESET}"; rm -rf "${backup_dir}"; echo -e "${C_GREEN}Source folder deleted.${C_RESET}"; else echo -e "${C_YELLOW}Original backup folder kept.${C_RESET}"; fi
    else
        echo -e "${C_BOLD_RED}Error: Failed to create RAR archive. Check logs for details.${C_RESET}"
    fi
}

volume_backup_main() {
    clear; echo -e "${C_GREEN}Starting Docker Volume Backup...${C_RESET}"; ensure_backup_image
    mapfile -t all_volumes < <($SUDO_CMD docker volume ls --format "{{.Name}}"); local -a filtered_volumes=()
    for volume in "${all_volumes[@]}"; do if [[ ! " ${IGNORED_VOLUMES[*]-} " =~ " ${volume} " ]]; then filtered_volumes+=("$volume"); fi; done
    if [[ ${#filtered_volumes[@]} -eq 0 ]]; then echo -e "${C_YELLOW}No available volumes to back up.${C_RESET}"; sleep 2; return; fi
    local -a selected_status=(); for ((i=0; i<${#filtered_volumes[@]}; i++)); do selected_status+=("true"); done
    if ! show_selection_menu "Select Volumes to BACKUP" "backup" filtered_volumes selected_status; then echo -e "${C_RED}Backup canceled.${C_RESET}"; return; fi
    local selected_volumes=(); for i in "${!filtered_volumes[@]}"; do if ${selected_status[$i]}; then selected_volumes+=("${filtered_volumes[$i]}"); fi; done
    if [[ ${#selected_volumes[@]} -eq 0 ]]; then echo -e "\n${C_RED}No volumes selected! Exiting.${C_RESET}"; return; fi
    local backup_dir="${BACKUP_LOCATION%/}/$(date +'%Y-%m-%d_%H-%M-%S')"; mkdir -p "$backup_dir"
    echo -e "\nBacking up ${#selected_volumes[@]} volume(s) to:\n${C_GREEN}${backup_dir}${C_RESET}\n"
    for volume in "${selected_volumes[@]}"; do
        echo -e "${C_YELLOW}Backing up ${C_BLUE}${volume}${C_RESET}..."
        execute_and_log $SUDO_CMD docker run --rm -v "${volume}:/volume:ro" -v "${backup_dir}:/backup" "${BACKUP_IMAGE}" tar -C /volume --zstd -cvf "/backup/${volume}.tar.zst" .
    done
    echo -e "\n${C_YELLOW}Changing ownership of backup files to user '${CURRENT_USER}'...${C_RESET}"
    $SUDO_CMD chown -R "${CURRENT_USER}:${CURRENT_USER}" "$backup_dir"
    echo -e "\n${C_GREEN}${TICKMARK} All backups completed successfully!${C_RESET}"

    # --- BEGIN: Modified Secure RAR Archive Creation ---
    read -p $'\n'"Do you want to create a single, password-protected RAR archive from this backup? (Y/n): " create_rar
    if [[ ! "$(echo "${create_rar:-y}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|yes)$ ]]; then
        echo -e "${C_YELLOW}Skipping RAR archive creation.${C_RESET}"
        return
    fi

    if ! command -v rar &>/dev/null; then
        echo -e "\n${C_BOLD_RED}Error: 'rar' command not found.${C_RESET}" >&2
        echo -e "${C_YELLOW}Please install it to use this feature (e.g., 'sudo apt-get install rar').${C_RESET}" >&2
        return 1
    fi

    local archive_password="${RAR_PASSWORD-}"
    if [[ -z "$archive_password" ]]; then
        read -sp "Enter password for the archive (input is hidden): " archive_password; echo
        if [[ -z "$archive_password" ]]; then
            echo -e "${C_RED}No password provided. Aborting RAR creation.${C_RESET}"; return
        fi
    fi

    # MODIFIED: New archive name format
    local archive_name; archive_name="Apps-backup[$(date +'%d.%m.%Y')].rar"
    local archive_path; archive_path="$(dirname "$backup_dir")/${archive_name}"

    # MODIFIED: Logic to ask for splitting large archives
    local rar_split_opt=""
    local total_size; total_size=$(du -sb "$backup_dir" | awk '{print $1}')
    local eight_gb=$((8 * 1024 * 1024 * 1024))
    if (( total_size > eight_gb )); then
        read -p "Backup size is over 8GB. Split archive into 8GB parts? (Y/n): " confirm_split
        if [[ "$(echo "${confirm_split:-y}" | tr '[:upper:]' '[:lower:]')" =~ ^(y|yes)$ ]]; then
            rar_split_opt="-v8g"
            echo -e "${C_YELLOW}Archive will be split into 8GB files.${C_RESET}"
        fi
    fi

    echo -e "\n${C_YELLOW}Creating secure RAR archive: ${C_GREEN}${archive_path}${C_RESET}"
    echo -e "${C_GRAY}(This may take some time...)${C_RESET}"

    # MODIFIED: Added -ep1 to strip base path and ${rar_split_opt} for splitting
    # -hp encrypts file data and headers. -ep1 excludes base directory.
    if execute_and_log rar a -ep1 ${rar_split_opt} "-m${RAR_COMPRESSION_LEVEL:-3}" "-hp${archive_password}" -- "${archive_path}" "${backup_dir}"; then
        echo -e "${C_GREEN}${TICKMARK} Secure archive created successfully.${C_RESET}"
        $SUDO_CMD chown "${CURRENT_USER}:${CURRENT_USER}" "${archive_path}"*

        local should_delete_source=${RAR_DELETE_SOURCE_AFTER:-false}
        local prompt_text="Delete the original backup folder ('${backup_dir}')?"
        local prompt_opts=$([[ "$should_delete_source" == "true" ]] && echo "Y/n" || echo "y/N")
        read -p "${prompt_text} [${prompt_opts}]: " confirm_del

        local final_decision=false
        if [[ "${confirm_del,,}" == "y" ]] || [[ "${confirm_del,,}" == "yes" ]]; then
            final_decision=true
        elif [[ -z "$confirm_del" && "$should_delete_source" == "true" ]]; then
            final_decision=true
        fi

        if $final_decision; then
            echo -e "${C_YELLOW}Deleting source folder...${C_RESET}"
            rm -rf "${backup_dir}"
            echo -e "${C_GREEN}Source folder deleted.${C_RESET}"
        else
            echo -e "${C_YELLOW}Original backup folder kept.${C_RESET}"
        fi
    else
        echo -e "${C_BOLD_RED}Error: Failed to create RAR archive. Check logs for details.${C_RESET}"
    fi
    # --- END: Modified Secure RAR Archive Creation ---
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
    if [[ ! "${confirm,,}" =~ ^(y|yes)$ ]]; then echo -e "${C_RED}Restore canceled.${C_RESET}"; return; fi
    
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
        "Backup Volumes (Standard)"
        "Restore Volumes"
        "Inspect / Manage a Volume"
        "Return to Main Menu"
    )
    while true; do
        clear
        echo -e "==============================================\n   ${C_GREEN}Volume Manager${C_RESET}\n=============================================="
        for i in "${!options[@]}"; do echo -e " ${C_YELLOW}$((i+1)))${C_RESET} ${options[$i]}"; done
        echo "----------------------------------------------"
        read -rp "Please select an option: " choice
        case "$choice" in
            1) volume_smart_backup_main; echo -e "\nPress Enter to return..."; read -r;;
            2) volume_backup_main; echo -e "\nPress Enter to return..."; read -r;;
            3) volume_restore_main; echo -e "\nPress Enter to return..."; read -r;;
            4) volume_checker_main ;;
            5) return ;;
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
    read -r -p "$(printf "${C_BOLD_RED}This action is IRREVERSIBLE. Are you sure? [y/N]: ${C_RESET}")" confirm
    if [[ "${confirm,,}" =~ ^(y|yes)$ ]]; then
        echo -e "\n${C_YELLOW}Pruning system...${C_RESET}"
        execute_and_log $SUDO_CMD docker system prune -af
        echo -e "\n${C_GREEN}${TICKMARK} System prune complete.${C_RESET}"
    else
        echo -e "\n${C_RED}Prune canceled.${C_RESET}"
    fi
}

log_viewer_main() {
    local less_prompt="(Scroll with arrow keys, press 'q' to return to this menu)"
    while true; do
        clear
        mapfile -t log_files < <(find "$LOG_DIR" -name "*.log" -type f | sort -r)

        if [ ${#log_files[@]} -eq 0 ]; then
            echo -e "${C_YELLOW}No log files found in ${LOG_DIR}.${C_RESET}"; sleep 2; return
        fi

        echo -e "${C_YELLOW}--- Log Viewer ---${C_RESET}\nSelect a log file to view:"
        
        local -a display_options=()
        for file in "${log_files[@]}"; do
            display_options+=("$(realpath --relative-to="$LOG_DIR" "$file")")
        done
        display_options+=("Return to Main Menu")
        
        PS3=$'\n'"Enter your choice: "
        select choice in "${display_options[@]}"; do
            if [[ "$choice" == "Return to Main Menu" ]]; then
                return
            ## MODIFIED: Added the missing 'then' keyword to fix the syntax error.
            elif [[ -n "$choice" ]]; then
                local idx=$((REPLY - 1))
                less -RFX --prompt="$less_prompt" "${log_files[$idx]}"
                break
            else
                echo -e "${C_RED}Invalid option. Please try again.${C_RESET}"; sleep 1; break
            fi
        done
    done
}


# ======================================================================================
# --- SECTION 6: MAIN SCRIPT EXECUTION ---
# ======================================================================================

main_menu() {
    while true; do
        clear
        echo -e "==============================================\n   ${C_GREEN}Docker Tool Suite${C_RESET} - Welcome, ${C_BLUE}${CURRENT_USER}${C_RESET}\n=============================================="
        echo -e " ${C_YELLOW}1)${C_RESET} Application Manager"
        echo -e " ${C_YELLOW}2)${C_RESET} Volume Manager"
        echo -e " ${C_YELLOW}3)${C_RESET} View Logs"
        echo -e " ${C_YELLOW}4)${C_RESET} Clean Up Docker System"
        echo -e " ${C_YELLOW}5)${C_RESET} Quit"
        echo "----------------------------------------------"
        read -rp "Please select an option [1-5]: " choice
        case "$choice" in
            1) app_manager_menu ;;
            2) volume_manager_menu ;;
            3) log_viewer_main ;;
            4) system_prune_main; echo -e "\nPress Enter to return..."; read -r ;;
            5) log "Exiting script." "${C_GRAY}Exiting.${C_RESET}"; exit 0 ;;
            *) echo -e "\n${C_RED}Invalid option: '$choice'.${C_RESET}"; sleep 1 ;;
        esac
    done
}

if [[ $# -gt 0 ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then echo -e "${C_RED}Config not found. Please run with 'sudo' for initial setup.${C_RESET}"; exit 1; fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    LOG_FILE="$LOG_DIR/$(date +'%Y-%m-%d').log"; mkdir -p "$LOG_DIR"
    case "$1" in
        update)
            shift; [[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
            [[ "${1:-}" == "--cron" ]] && echo "--- Running in automated cron mode ---" >> "$LOG_FILE"
            app_manager_update_all_known_apps
            exit 0 ;;
        *) echo "Unknown command: $1"; echo "Usage: $0 [update|--help]"; exit 1 ;;
    esac
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    initial_setup
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"
LOG_FILE="$LOG_DIR/$(date +'%Y-%m-%d').log"; mkdir -p "$LOG_DIR"
check_deps
main_menu
