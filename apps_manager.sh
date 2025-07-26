#!/bin/bash

# ==============================================================================
# Universal Docker Apps Manager
#
# A script to manage Docker Compose applications organized in a specific
# directory structure. It supports "essential" apps and selectable "managed"
# apps, with features for starting, stopping, and viewing their status.
# ==============================================================================

# --- Strict Mode ---
set -euo pipefail

# --- Colors for script output ---
C_RED='\e[31m'
C_GREEN='\e[32m'
C_YELLOW='\e[33m'
C_BLUE='\e[34m'
C_GRAY='\e[90m'
C_RESET='\e[0m'

# --- Default Configuration (can be overridden by external config file) ---
APPS_BASE_PATH="$HOME/apps"
MANAGED_SUBDIR="managed_stacks"
LOG_DIR="/home/pavdig/logs/app_manager_logs"
CONFIG_DIR="$HOME/.config/app_manager"
CONFIG_FILE="$CONFIG_DIR/config.sh"

# --- Function to create and source the external configuration ---
setup_and_load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${C_YELLOW}Configuration file not found. Creating a default one at '$CONFIG_FILE'...${C_RESET}"
        mkdir -p "$CONFIG_DIR"
        cat > "$CONFIG_FILE" << EOL
#!/bin/bash
# --- User Configuration for App Manager ---
# Base path where all your application directories are stored.
APPS_BASE_PATH="$HOME/apps"
# Subdirectory within APPS_BASE_PATH for apps to manage individually.
MANAGED_SUBDIR="managed_stacks"
# Directory for log files.
LOG_DIR="/home/pavdig/logs/app_manager_logs"
EOL
        echo -e "${C_GREEN}Default config created. Please review it and re-run the script if needed.${C_RESET}"
        sleep 2
    fi
    # Source the configuration file to override defaults
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

# --- Logging Setup ---
setup_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/$(date +'%Y-%m-%d').log"
}

# Function for logging with a timestamp. Used for high-level events.
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo -e "$2" # Print colored/formatted message to console
}

# --- Core Functions ---

check_deps() {
    log "Checking dependencies..." "${C_GRAY}Checking dependencies...${C_RESET}"
    if ! command -v docker &> /dev/null; then
        log "Error: Docker not found." "${C_RED}Error: Docker is not installed or not in your PATH.${C_RESET}"
        exit 1
    fi
    if ! docker compose version &> /dev/null; then
        log "Error: Docker Compose V2 not found." "${C_RED}Error: Docker Compose V2 plugin is not available.${C_RESET}"
        exit 1
    fi
    log "Dependencies check passed." ""
}

find_compose_file() {
    local app_dir="$1"
    local compose_files=("compose.yaml" "compose.yml" "docker-compose.yaml" "docker-compose.yml")
    for file in "${compose_files[@]}"; do
        if [ -f "$app_dir/$file" ]; then
            echo "$app_dir/$file"
            return 0
        fi
    done
    return 1
}

discover_apps() {
    local path="$1"
    local -n app_array="$2"
    app_array=()
    if [ ! -d "$path" ]; then
        echo "Warning: Directory not found for discovery: $path" >> "$LOG_FILE"
        return
    fi
    for dir in "$path"/*; do
        if [ -d "$dir" ]; then
            app_array+=("$(basename "$dir")")
        fi
    done
    IFS=$'\n' app_array=($(sort <<<"${app_array[*]}"))
    unset IFS
}

# (Internal) Function to process a single start action.
_start_app_task() {
    local app_name="$1"
    local app_dir="$2"
    local log_file="$3"
    local compose_file
    
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Processing $app_name..." >> "$log_file"
    compose_file=$(find_compose_file "$app_dir")
    if [ -z "$compose_file" ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] Warning: No compose file for '$app_name'. Skipping." >> "$log_file"
        return
    fi
    
    if docker compose -f "$compose_file" pull >> "$log_file" 2>&1; then
        docker compose -f "$compose_file" up -d >> "$log_file" 2>&1
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] Successfully started '$app_name'." >> "$log_file"
    else
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Failed to pull images for '$app_name'. Aborting start." >> "$log_file"
    fi
}

# (Internal) Function to process a single stop action.
_stop_app_task() {
    local app_name="$1"
    local app_dir="$2"
    local log_file="$3"
    local compose_file

    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Stopping $app_name..." >> "$log_file"
    compose_file=$(find_compose_file "$app_dir")
    if [ -z "$compose_file" ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] Info: No compose file for '$app_name'. Cannot stop." >> "$log_file"
        return
    fi

    docker compose -f "$compose_file" down --remove-orphans >> "$log_file" 2>&1
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Successfully stopped '$app_name'." >> "$log_file"
}

# --- UI and Workflow Functions ---

show_selection_menu() {
    local title="$1"
    local action_verb="$2"
    local -n all_apps_ref="$3"
    local -n selected_status_ref="$4"
    while true; do
        clear
        echo -e "=====================================================\n ${C_GREEN}${title}${C_RESET}\n Use number to toggle, (a) to toggle all\n====================================================="
        for i in "${!all_apps_ref[@]}"; do
            if ${selected_status_ref[$i]}; then
                echo -e " $((i+1)). ${C_GREEN}[x]${C_RESET} ${all_apps_ref[$i]}"
            else
                echo -e " $((i+1)). ${C_RED}[ ]${C_RESET} ${all_apps_ref[$i]}"
            fi
        done
        echo "-----------------------------------------------------"
        echo "Enter a number, (a)ll, (${action_verb:0:1}) to ${action_verb} selected, or (q)uit."
        read -rp "Your choice: " choice
        case "$choice" in
            [sS] | [${action_verb:0:1}]) return 0 ;;
            [qQ]) return 1 ;;
            [aA])
                all_selected=true
                for status in "${selected_status_ref[@]}"; do if ! $status; then all_selected=false; break; fi; done
                new_status=$(if $all_selected; then echo "false"; else echo "true"; fi)
                for i in "${!selected_status_ref[@]}"; do selected_status_ref[$i]=$new_status; done ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#all_apps_ref[@]}" ]; then
                    local index=$((choice-1))
                    if ${selected_status_ref[$index]}; then selected_status_ref[$index]=false; else selected_status_ref[$index]=true; fi
                else
                    echo -e "${C_RED}Invalid input. Press Enter to continue...${C_RESET}"; read -r
                fi ;;
        esac
    done
}

show_status() {
    clear
    log "Generating App Status Overview" "${C_BLUE}================ App Status Overview ================${C_RESET}"
    declare -A running_projects
    while read -r proj; do [[ -n "$proj" ]] && running_projects["$proj"]=1; done < <(docker compose ls --quiet)

    echo -e "\n${C_YELLOW}--- Essential Apps (${APPS_BASE_PATH}) ---${C_RESET}"
    local -a essential_apps
    discover_apps "$APPS_BASE_PATH" essential_apps
    if [ ${#essential_apps[@]} -eq 0 ]; then
        echo "No essential apps found."
    else
        for app in "${essential_apps[@]}"; do
            if [ "$app" != "$MANAGED_SUBDIR" ]; then
                if [[ -v running_projects[$app] ]]; then echo -e " ${C_GREEN}[RUNNING]${C_RESET}\t$app"; else echo -e " ${C_RED}[STOPPED]${C_RESET}\t$app"; fi
            fi
        done
    fi

    echo -e "\n${C_YELLOW}--- Managed Apps (${MANAGED_SUBDIR}) ---${C_RESET}"
    local -a managed_apps
    local managed_path="$APPS_BASE_PATH/$MANAGED_SUBDIR"
    discover_apps "$managed_path" managed_apps
    if [ ${#managed_apps[@]} -eq 0 ]; then
        echo "No managed apps found."
    else
        for app in "${managed_apps[@]}"; do
            if [[ -v running_projects[$app] ]]; then echo -e " ${C_GREEN}[RUNNING]${C_RESET}\t$app"; else echo -e " ${C_RED}[STOPPED]${C_RESET}\t$app"; fi
        done
    fi
    echo -e "\n${C_BLUE}====================================================${C_RESET}"
    read -rp "Press Enter to return to the main menu..."
}

handle_action() {
    local action_func="$1"
    local message="$2"
    log "$message" "${C_GREEN}${message} in the background... See log for details.${C_RESET}"
    
    local -a app_list; local base_path; local task_func
    case "$action_func" in
        start_essentials)
            discover_apps "$APPS_BASE_PATH" app_list
            base_path="$APPS_BASE_PATH"
            task_func=_start_app_task
            ;;
        stop_essentials)
            discover_apps "$APPS_BASE_PATH" app_list
            base_path="$APPS_BASE_PATH"
            task_func=_stop_app_task
            ;;
    esac

    if [ ${#app_list[@]} -eq 0 ]; then log "No apps found for this action." ""; return; fi
    
    for app in "${app_list[@]}"; do
        if [ "$app" != "$MANAGED_SUBDIR" ]; then
            $task_func "$app" "$base_path/$app" "$LOG_FILE" &
        fi
    done
    wait
    log "All '$message' processes finished." ""
}

start_selected() {
    local managed_path="$APPS_BASE_PATH/$MANAGED_SUBDIR"
    local -a all_selectable_apps; local -a selected_status=()
    discover_apps "$managed_path" all_selectable_apps
    if [ ${#all_selectable_apps[@]} -eq 0 ]; then log "No managed apps found." "${C_YELLOW}No managed apps found.${C_RESET}"; return; fi
    
    for ((i=0; i<${#all_selectable_apps[@]}; i++)); do selected_status+=("true"); done
    if ! show_selection_menu "Select Managed Apps to START" "start" all_selectable_apps selected_status; then log "User quit. No apps started." ""; return; fi
    
    log "Starting Selected Managed Apps" "${C_GREEN}Starting selected apps in the background... See log for details.${C_RESET}"
    for i in "${!all_selectable_apps[@]}"; do
        if ${selected_status[$i]}; then _start_app_task "${all_selectable_apps[$i]}" "$managed_path/${all_selectable_apps[$i]}" "$LOG_FILE" & fi
    done
    wait
    log "All selected managed app start processes finished." ""
}

stop_selected() {
    local managed_path="$APPS_BASE_PATH/$MANAGED_SUBDIR"
    local -a all_selectable_apps; local -a selected_status=()
    discover_apps "$managed_path" all_selectable_apps
    if [ ${#all_selectable_apps[@]} -eq 0 ]; then log "No managed apps found to stop." "${C_YELLOW}No managed apps found to stop.${C_RESET}"; return; fi
    
    declare -A running_apps_map
    while read -r project; do [[ -n "$project" ]] && running_apps_map["$project"]=1; done < <(docker compose ls --quiet)
    for app in "${all_selectable_apps[@]}"; do if [[ -v running_apps_map[$app] ]]; then selected_status+=("true"); else selected_status+=("false"); fi; done
    
    if ! show_selection_menu "Select Managed Apps to STOP" "stop" all_selectable_apps selected_status; then log "User quit. No apps stopped." ""; return; fi
    
    log "Stopping Selected Managed Apps" "${C_YELLOW}Stopping selected apps in the background... See log for details.${C_RESET}"
    for i in "${!all_selectable_apps[@]}"; do
        if ${selected_status[$i]}; then _stop_app_task "${all_selectable_apps[$i]}" "$managed_path/${all_selectable_apps[$i]}" "$LOG_FILE" & fi
    done
    wait
    log "All selected managed app stop processes finished." ""
}

stop_all() {
    log "Stopping ALL running Docker Compose projects" "${C_YELLOW}Stopping all projects in the background... See log for details.${C_RESET}"
    local projects
    projects=$(docker compose ls --quiet)
    if [ -z "$projects" ]; then log "No running Docker Compose projects found." "${C_GREEN}No running Docker Compose projects found to stop.${C_RESET}"; return; fi
    
    echo "$projects" | while read -r project; do
        if [ -n "$project" ]; then
            (
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] Stopping project: $project" >> "$LOG_FILE"
                docker compose -p "$project" down --remove-orphans >> "$LOG_FILE" 2>&1
            ) &
        fi
    done
    wait
    log "All Docker Compose project stop processes finished." ""
}

# --- Main Script Logic (FIXED) ---
main() {
    setup_and_load_config
    setup_logging
    check_deps
    
    options=(
        "Show App STATUS"
        "Start ESSENTIAL apps"
        "Start MANAGED apps"
        "Stop ESSENTIAL apps"
        "Stop MANAGED apps"
        "STOP ALL RUNNING APPS"
        "Quit"
    )

    while true; do
        clear
        echo -e "==============================================\n   ${C_GREEN}Universal Docker Apps Manager${C_RESET}\n=============================================="
        
        # Manually print the options for better control
        for i in "${!options[@]}"; do
            echo -e " ${C_YELLOW}$((i+1)))${C_RESET} ${options[$i]}"
        done
        echo "----------------------------------------------"

        read -rp "Please select an option: " choice

        case "$choice" in
            1)
                show_status
                ;;
            2)
                handle_action "start_essentials" "Starting Essential Apps"
                echo -e "\n${C_BLUE}Task initiated. Press Enter to return to menu...${C_RESET}"; read -r
                ;;
            3)
                start_selected
                echo -e "\n${C_BLUE}Task initiated. Press Enter to return to menu...${C_RESET}"; read -r
                ;;
            4)
                handle_action "stop_essentials" "Stopping Essential Apps"
                echo -e "\n${C_BLUE}Task initiated. Press Enter to return to menu...${C_RESET}"; read -r
                ;;
            5)
                stop_selected
                echo -e "\n${C_BLUE}Task initiated. Press Enter to return to menu...${C_RESET}"; read -r
                ;;
            6)
                stop_all
                echo -e "\n${C_BLUE}Task initiated. Press Enter to return to menu...${C_RESET}"; read -r
                ;;
            7)
                log "Exiting script." "${C_GRAY}Exiting.${C_RESET}"
                exit 0
                ;;
            "") # User pressed Enter without input - this is a clean no-op
                continue
                ;;
            *)
                echo -e "\n${C_RED}Invalid option: '$choice'. Please try again.${C_RESET}"
                sleep 2
                ;;
        esac
    done
}

# Run the main function
main "$@"
