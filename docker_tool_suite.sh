#!/bin/bash
# ======================================================================================
# Docker Tool Suite
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
        interactive_list_builder "Select Volumes to IGNORE" all_volumes selected_ignored_volumes
    fi
    
    local -a selected_ignored_images=()
    read -p $'\n'"Do you want to configure ignored images now? (y/N): " config_imgs
    if [[ "${config_imgs,,}" =~ ^(y|yes)$ ]]; then
        mapfile -t all_images < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)
        interactive_list_builder "Select Images to IGNORE" all_images selected_ignored_images
    fi

    clear
    echo -e "\n${C_GREEN}_--| Docker Tool Suite Setup |---_${C_RESET}\n"
    echo -e "${C_YELLOW}--- Configuration Summary ---${C_RESET}"
    echo "  App Manager:"
    echo -e "    Base Path:       ${C_GREEN}${APPS_BASE_PATH}${C_RESET}"
    echo -e "    Managed Subdir:  ${C_GREEN}${MANAGED_SUBDIR}${C_RESET}"
    echo "  Volume Manager:"
    echo -e "    Backup Path:     ${C_GREEN}${BACKUP_LOCATION}${C_RESET}"
    echo -e "    Restore Path:    ${C_GREEN}${RESTORE_LOCATION}${C_RESET}"
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
            printf "\n"; echo "    \"example-of-ignored_volume-1\""; echo "    \"example-of-ignored_volume-2\""
        fi
        echo ")"
        echo
        echo "# --- Image Updater ---"
        echo "# List of Docker images to ignore during updates."
        echo -n "IGNORED_IMAGES=("
        if [ ${#selected_ignored_images[@]} -gt 0 ]; then
            printf "\n"; for img in "${selected_ignored_images[@]}"; do echo "    \"$img\""; done
        else
            printf "\n"; echo "    \"example-of-image_to-ignore:latest\""; echo "    \"example-of-image_to-ignore:<none>\""
        fi
        echo ")"
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
    read -p "Would you like to schedule the image updater to run automatically? (Y/n): " schedule_now
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
        clear; echo -e "${C_YELLOW}Choose a schedule for the image updater (for user: ${C_GREEN}$cron_target_user${C_YELLOW}):${C_RESET}\n"
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
    # MODIFIED: Command needs to use sudo for cron
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
    # MODIFIED: Use $SUDO_CMD
    if $SUDO_CMD docker compose -f "$compose_file" pull >> "$LOG_FILE" 2>&1; then
        $SUDO_CMD docker compose -f "$compose_file" up -d >> "$LOG_FILE" 2>&1
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
    # MODIFIED: Use $SUDO_CMD
    $SUDO_CMD docker compose -f "$compose_file" down --remove-orphans >> "$LOG_FILE" 2>&1
    log "Successfully stopped '$app_name'."
}

_update_app_task() {
    local app_name="$1" app_dir="$2"
    log "Updating $app_name..."
    local compose_file; compose_file=$(find_compose_file "$app_dir")
    if [ -z "$compose_file" ]; then log "Warning: No compose file for '$app_name'. Skipping." ""; return; fi
    
    local was_running=false
    # MODIFIED: Use $SUDO_CMD
    if $SUDO_CMD docker compose -f "$compose_file" ps --status=running | grep -q 'running'; then
        was_running=true
    fi

    # MODIFIED: Use $SUDO_CMD
    if $SUDO_CMD docker compose -f "$compose_file" pull >> "$LOG_FILE" 2>&1; then
        log "Pull successful for $app_name."
        if $was_running; then
            log "Restarting running application '$app_name'..."
            $SUDO_CMD docker compose -f "$compose_file" up -d --remove-orphans >> "$LOG_FILE" 2>&1
            log "Successfully updated and restarted '$app_name'."
        else
            log "Application '$app_name' was not running. Image updated, but app remains stopped."
        fi
    else
        log "ERROR: Failed to pull new images for '$app_name'. Aborting update."
        echo -e "${C_BOLD_RED}Failed to pull new images for '$app_name'. Check log for details.${C_RESET}"
    fi
}

app_manager_status() {
    clear; log "Generating App Status Overview" "${C_BLUE}Displaying App Status Overview...${C_RESET}"
    local less_prompt="(Scroll with arrow keys, press 'q' to return)"
    (
        declare -A running_projects
        # MODIFIED: Use $SUDO_CMD
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

app_manager_handle_essentials() {
    local action="$1" message="$2" task_func="$3"
    log "$message" "${C_GREEN}${message} in the background... See log for details.${C_RESET}"
    local -a app_list; discover_apps "$APPS_BASE_PATH" app_list
    if [ ${#app_list[@]} -eq 0 ]; then log "No essential apps found." ""; return; fi
    for app in "${app_list[@]}"; do
        if [ "$app" != "$MANAGED_SUBDIR" ]; then
            $task_func "$app" "$APPS_BASE_PATH/$app" &
        fi
    done
    wait
    log "All '$message' processes finished."
}

app_manager_handle_managed() {
    local action="$1" title="$2" task_func="$3"
    local managed_path="$APPS_BASE_PATH/$MANAGED_SUBDIR"
    local -a all_apps; discover_apps "$managed_path" all_apps
    if [ ${#all_apps[@]} -eq 0 ]; then log "No managed apps found for this action." "${C_YELLOW}No managed apps found.${C_RESET}"; return; fi
    
    local -a selected_status=()
    if [[ "$action" == "stop" || "$action" == "update" ]]; then
        [[ "$action" == "stop" ]] && title="Select Apps to STOP (defaults to running)"
        [[ "$action" == "update" ]] && title="Select Apps to UPDATE (defaults to running)"
        declare -A running_apps_map
        # MODIFIED: Use $SUDO_CMD
        while read -r project; do [[ -n "$project" ]] && running_apps_map["$project"]=1; done < <($SUDO_CMD docker compose ls --quiet)
        for app in "${all_apps[@]}"; do if [[ -v running_apps_map[$app] ]]; then selected_status+=("true"); else selected_status+=("false"); fi; done
    else
        for ((i=0; i<${#all_apps[@]}; i++)); do selected_status+=("true"); done
    fi

    local menu_result; show_selection_menu "$title" "$action" all_apps selected_status "update"
    menu_result=$?

    if [[ $menu_result -eq 1 ]]; then log "User quit. No action taken." ""; return; fi
    if [[ $menu_result -eq 2 ]]; then action="update"; task_func="_update_app_task"; fi
    
    log "Performing '$action' on selected managed apps" "${C_GREEN}Processing selected apps... See log for details.${C_RESET}"
    for i in "${!all_apps[@]}"; do
        if ${selected_status[$i]}; then $task_func "${all_apps[$i]}" "$managed_path/${all_apps[$i]}" & fi
    done
    wait
    log "All selected managed app processes for '$action' finished."
}

app_manager_stop_all() {
    log "Stopping ALL running Docker Compose projects" "${C_YELLOW}Stopping all projects... See log for details.${C_RESET}"
    # MODIFIED: Use $SUDO_CMD
    local projects; projects=$($SUDO_CMD docker compose ls --quiet)
    if [ -z "$projects" ]; then log "No running projects found." "${C_GREEN}No running projects found to stop.${C_RESET}"; return; fi
    echo "$projects" | while read -r project; do
        if [ -n "$project" ]; then
            (
                log "Stopping project: $project"
                # MODIFIED: Use $SUDO_CMD
                $SUDO_CMD docker compose -p "$project" down --remove-orphans >> "$LOG_FILE" 2>&1
            ) &
        fi
    done
    wait
    log "All Docker Compose project stop processes finished."
}

app_manager_menu() {
    # MODIFIED: check_root handles auth now, not just menu functions
    check_root
    local options=( "Show App STATUS" "Start ESSENTIAL apps" "Stop ESSENTIAL apps" "Update ESSENTIAL apps" "Manage INDIVIDUAL apps (Start/Stop/Update)" "STOP ALL RUNNING APPS" "Return to Main Menu" )
    while true; do
        clear
        echo -e "==============================================\n   ${C_GREEN}Application Manager${C_RESET}\n=============================================="
        for i in "${!options[@]}"; do echo -e " ${C_YELLOW}$((i+1)))${C_RESET} ${options[$i]}"; done
        echo "----------------------------------------------"
        read -rp "Please select an option: " choice
        case "$choice" in
            1) app_manager_status ;;
            2) app_manager_handle_essentials "start" "Starting Essential Apps" "_start_app_task"; echo -e "\n${C_BLUE}Task complete. Press Enter...${C_RESET}"; read -r ;;
            3) app_manager_handle_essentials "stop" "Stopping Essential Apps" "_stop_app_task"; echo -e "\n${C_BLUE}Task complete. Press Enter...${C_RESET}"; read -r ;;
            4) app_manager_handle_essentials "update" "Updating Essential Apps" "_update_app_task"; echo -e "\n${C_BLUE}Task complete. Press Enter...${C_RESET}"; read -r ;;
            5) app_manager_handle_managed "start" "Select Managed Apps to START" "_start_app_task"; echo -e "\n${C_BLUE}Task complete. Press Enter...${C_RESET}"; read -r ;;
            6) app_manager_stop_all; echo -e "\n${C_BLUE}Task complete. Press Enter...${C_RESET}"; read -r ;;
            7) return ;;
            *) echo -e "\n${C_RED}Invalid option.${C_RESET}"; sleep 1 ;;
        esac
    done
}


# ======================================================================================
# --- SECTION 3: IMAGE UPDATER MODULE ---
# ======================================================================================

image_updater_main() {
    check_root
    log "Starting image update process for RUNNING containers..."
    if $DRY_RUN; then log "--- Starting in Dry Run mode ---" "${C_YELLOW}--- Starting in Dry Run mode. No changes will be made. ---${C_RESET}"; fi

    # MODIFIED: Use $SUDO_CMD
    mapfile -t running_images < <($SUDO_CMD docker ps --format '{{.Image}}' | sort -u)
    if [ ${#running_images[@]} -eq 0 ]; then
        log "No running containers found." "${C_YELLOW}No running containers found to update.${C_RESET}"; return
    fi

    local -a images_to_update=()
    local ignored_pattern=""
    if [[ ${#IGNORED_IMAGES[@]} -gt 0 ]]; then
        ignored_pattern=$(IFS="|"; echo "${IGNORED_IMAGES[*]}")
    fi

    for image in "${running_images[@]}"; do
        if [[ -n "$ignored_pattern" ]] && echo "$image" | grep -qE "$ignored_pattern"; then
            log "Skipping ignored image: $image"
        else
            images_to_update+=("$image")
        fi
    done

    if [ ${#images_to_update[@]} -eq 0 ]; then
        log "No images to update after filtering." "${C_GREEN}All running container images are on the ignore list. Nothing to do.${C_RESET}"; return
    fi

    log "Found ${#images_to_update[@]} active images to update. Pulling..." "${C_GREEN}Found ${#images_to_update[@]} active images to update. Pulling...${C_RESET}"
    local pull_errors=0
    for image in "${images_to_update[@]}"; do
        (
            if $DRY_RUN; then
                log "[Dry Run] Would pull image: $image"
            else
                log "Pulling: $image"
                # MODIFIED: Use $SUDO_CMD
                if ! $SUDO_CMD docker pull "$image" >> "$LOG_FILE" 2>&1; then
                    log "ERROR: Failed to pull $image"
                    pull_errors=$((pull_errors + 1))
                fi
            fi
        ) &
    done
    wait

    log "All image pulls complete."
    if [[ $pull_errors -gt 0 ]]; then log "WARNING: There were $pull_errors errors. Check log." "${C_YELLOW}WARNING: There were $pull_errors errors during the pull process. Check log.${C_RESET}"; else log "All images pulled successfully." "${C_GREEN}All images pulled successfully.${C_RESET}"; fi

    if ! $DRY_RUN; then
        log "Cleaning up old, dangling images..." "${C_GREEN}Cleaning up old, dangling images...${C_RESET}"
        # MODIFIED: Use $SUDO_CMD
        local prune_output; prune_output=$($SUDO_CMD docker image prune -f); log "Prune Output: $prune_output" "$prune_output"
    else
        log "[Dry Run] Would run 'sudo docker image prune -f'." "${C_YELLOW}[Dry Run] Would run 'sudo docker image prune -f'.${C_RESET}"
    fi
    
    log "--- Image Update Summary ---"
    log "Images checked: ${#running_images[@]}"
    log "Images updated: $((${#images_to_update[@]} - pull_errors))"
    log "Update process finished."
    echo -e "\n${C_YELLOW}Note: Containers must be restarted to use the new images.${C_RESET}"
}


# ======================================================================================
# --- SECTION 4: VOLUME MANAGER & CHECKER MODULE ---
# ======================================================================================

ensure_backup_image() {
    log "Checking for backup image: $BACKUP_IMAGE" "-> Checking for Docker image: ${C_BLUE}${BACKUP_IMAGE}${C_RESET}..."
    # MODIFIED: Use $SUDO_CMD
    if ! $SUDO_CMD docker image inspect "${BACKUP_IMAGE}" &>/dev/null; then
        log "Image not found, pulling..." "   -> Image not found locally. Pulling..."
        if ! $SUDO_CMD docker pull "${BACKUP_IMAGE}"; then log "ERROR: Failed to pull backup image." "${C_RED}Error: Failed to pull...${C_RESET}"; exit 1; fi
    fi
    log "Backup image OK." "-> Image OK.\n"
}

# MODIFIED: Use $SUDO_CMD
run_in_volume() { local volume_name="$1"; shift; $SUDO_CMD docker run --rm -v "${volume_name}:/volume:ro" "${BACKUP_IMAGE}" "$@"; }

volume_checker_inspect() {
    local volume_name="$1"
    # MODIFIED: Use $SUDO_CMD
    echo -e "\n${C_BLUE}--- Inspecting '${volume_name}' ---${C_RESET}"; $SUDO_CMD docker volume inspect "${volume_name}"
    echo -e "\n${C_BLUE}--- Listing files in '${volume_name}' ---${C_RESET}"; run_in_volume "${volume_name}" ls -lah /volume
    echo -e "\n${C_BLUE}--- Calculating total size of '${volume_name}' ---${C_RESET}"; run_in_volume "${volume_name}" du -sh /volume
    echo -e "\n${C_BLUE}--- Top 10 largest files/folders in '${volume_name}' ---${C_RESET}"; run_in_volume "${volume_name}" sh -c 'du -ah /volume | sort -hr | head -n 10'
}

volume_checker_explore() {
    local volume_name="$1"
    echo -e "\n${C_BLUE}--- Interactive Shell for '${volume_name}' ---${C_RESET}"
    echo -e "${C_YELLOW}The volume is mounted read-write at /volume.\nType 'exit' or press Ctrl+D to return.${C_RESET}"
    # MODIFIED: Use $SUDO_CMD
    $SUDO_CMD docker run --rm -it -v "${volume_name}:/volume" -w /volume "${BACKUP_IMAGE}" sh
}

volume_checker_remove() {
    local volume_name="$1"
    read -r -p "$(printf "\n${C_YELLOW}Permanently delete volume '${C_BLUE}%s${C_YELLOW}'? [y/N]: ${C_RESET}" "${volume_name}")" confirm
    if [[ "${confirm,,}" =~ ^(y|yes)$ ]]; then
        echo -e "-> Deleting volume '${volume_name}'..."
        # MODIFIED: Use $SUDO_CMD
        if $SUDO_CMD docker volume rm "${volume_name}"; then echo -e "${C_GREEN}Volume successfully deleted.${C_RESET}"; sleep 2; return 0; else echo -e "${C_RED}Error: Failed to delete. It might be in use.${C_RESET}"; sleep 3; return 1; fi
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
        # MODIFIED: Use $SUDO_CMD
        mapfile -t volumes < <($SUDO_CMD docker volume ls --format "{{.Name}}")
        if [ ${#volumes[@]} -eq 0 ]; then echo -e "${C_YELLOW}No Docker volumes found.${C_RESET}"; sleep 2; return; fi
        echo -e "\n${C_YELLOW}Please select a volume to manage:${C_RESET}"
        PS3=$'\n'"Enter number (or q to return): "; select volume_name in "${volumes[@]}"; do
            if [[ "$REPLY" == "q" ]]; then return; fi
            if [[ -n "$volume_name" ]]; then volume_checker_menu "${volume_name}"; break; else echo -e "${C_RED}Invalid selection.${C_RESET}"; fi
        done
    done
}

volume_backup_main() {
    clear; echo -e "${C_GREEN}Starting Docker Volume Backup...${C_RESET}"; ensure_backup_image
    # MODIFIED: Use $SUDO_CMD
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
        # MODIFIED: Use $SUDO_CMD
        $SUDO_CMD docker run --rm -v "${volume}:/volume:ro" -v "${backup_dir}:/backup" "${BACKUP_IMAGE}" tar -C /volume --zstd -cvf "/backup/${volume}.tar.zst" .
    done
    echo -e "\n${C_YELLOW}Changing ownership of backup files to user '${CURRENT_USER}'...${C_RESET}"
    # MODIFIED: Use $SUDO_CMD
    $SUDO_CMD chown -R "${CURRENT_USER}:${CURRENT_USER}" "$backup_dir"
    echo -e "\n${C_GREEN}${TICKMARK} All backups completed successfully!${C_RESET}"
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

        # MODIFIED: Use $SUDO_CMD
        if ! $SUDO_CMD docker volume inspect "$volume_name" &>/dev/null; then
            echo "   -> Volume does not exist. Creating..."
            local compose_project="${volume_name%%_*}"
            local compose_volume="${volume_name#*_}"
            $SUDO_CMD docker volume create --label "com.docker.compose.project=${compose_project}" --label "com.docker.compose.volume=${compose_volume}" "$volume_name" >/dev/null
        fi

        echo "   -> Importing data..."
        local tar_opts="-xvf"; [[ "$base_name" == *.zst ]] && tar_opts="--zstd -xvf"
        # MODIFIED: Use $SUDO_CMD
        $SUDO_CMD docker run --rm -v "${volume_name}:/target" -v "$(dirname "$backup_file"):/backup" "${BACKUP_IMAGE}" tar -C /target ${tar_opts} "/backup/${base_name}"
        echo -e "   ${C_GREEN}${TICKMARK} Restore for volume ${volume_name} completed.${C_RESET}"
    done
    echo -e "\n${C_GREEN}All selected restore tasks finished.${C_RESET}"
}

volume_manager_menu() {
    check_root
    local options=( "Backup Volumes" "Restore Volumes" "Inspect / Manage a Volume" "Return to Main Menu" )
    while true; do
        clear
        echo -e "==============================================\n   ${C_GREEN}Volume Manager${C_RESET}\n=============================================="
        for i in "${!options[@]}"; do echo -e " ${C_YELLOW}$((i+1)))${C_RESET} ${options[$i]}"; done
        echo "----------------------------------------------"
        read -rp "Please select an option: " choice
        case "$choice" in
            1) volume_backup_main; echo -e "\nPress Enter to return..."; read -r;;
            2) volume_restore_main; echo -e "\nPress Enter to return..."; read -r;;
            3) volume_checker_main ;;
            4) return ;;
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
        # MODIFIED: Use $SUDO_CMD
        $SUDO_CMD docker system prune -af
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
            echo -e "${C_YELLOW}No log files found in ${LOG_DIR}.${C_RESET}"
            sleep 2
            return
        fi

        echo -e "${C_YELLOW}--- Log Viewer ---${C_RESET}\nSelect a log file to view:"
        # MODIFIED: Include return option directly in menu
        local options=()
        for file in "${log_files[@]}"; do options+=("$(realpath --relative-to="$LOG_DIR" "$file")"); done
        options+=("Return to Main Menu")
        
        PS3=$'\n'"Enter your choice: "
        select choice in "${options[@]}"; do
            if [[ "$choice" == "Return to Main Menu" ]]; then
                return
            elif [[ -n "$choice" ]]; then
                less -RFX --prompt="$less_prompt" "$LOG_DIR/$choice"
                break
            else
                echo -e "${C_RED}Invalid option. Please try again.${C_RESET}"
                sleep 1
                break
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
        echo -e " ${C_YELLOW}3)${C_RESET} Update Active Application Images"
        echo -e " ${C_YELLOW}4)${C_RESET} View Logs"
        echo -e " ${C_YELLOW}5)${C_RESET} Clean Up Docker System"
        echo -e " ${C_YELLOW}6)${C_RESET} Quit"
        echo "----------------------------------------------"
        read -rp "Please select an option [1-6]: " choice
        case "$choice" in
            1) app_manager_menu ;;
            2) volume_manager_menu ;;
            3) image_updater_main; echo -e "\n${C_BLUE}Update process finished. Press Enter...${C_RESET}"; read -r ;;
            4) log_viewer_main ;;
            5) system_prune_main; echo -e "\nPress Enter to return..."; read -r ;;
            6) log "Exiting script." "${C_GRAY}Exiting.${C_RESET}"; exit 0 ;;
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
            image_updater_main; exit 0 ;;
        *) echo "Unknown command: $1"; echo "Usage: $0 [update|--help]"; exit 1 ;;
    esac
fi

# MODIFIED: Check if file exists, if not, trigger initial_setup
if [[ ! -f "$CONFIG_FILE" ]]; then
    # The initial_setup function has its own root check and will exit if not run with sudo.
    initial_setup
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"
LOG_FILE="$LOG_DIR/$(date +'%Y-%m-%d').log"; mkdir -p "$LOG_DIR"
check_deps
main_menu
