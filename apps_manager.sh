#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error when substituting.
# Pipelines return the exit status of the last command to exit with a non-zero status.
set -euo pipefail

# --- Colors ---
C_RED='\e[31m'
C_GREEN='\e[32m'
C_YELLOW='\e[33m'
C_BLUE='\e[34m'
C_GRAY='\e[90m'
C_RESET='\e[0m'

# --- Configuration ---
# Base path for essential apps' docker-compose files
ESSENTIALS_BASE_PATH="$HOME/apps"
# Base path for selected apps' docker-compose files
MANAGED_BASE_PATH="$HOME/apps/managed_stacks"

# List of essential Docker Compose project names
essential_apps=(
    "zoraxy"
    "wud"
    "homepage"
    "portainer"
    "dockge"
)

# List of all selectable Docker Compose project names
all_selectable_apps=(
    "myspeed"
    "languagetool"
    "convertx"
    "stirling-pdf"
    "it-tools"
    "immich"
    "metube"
    "crafty"
    "omni-tools"
    "searxng"
    "torrent-tools"
    "open-webui"
    "vaultwarden"
    "ollama"
    "emulatorjs"
    "jdownloader-2"
)

# List of apps to be selected by default when starting
default_selected_apps=(
    "myspeed"
    "languagetool"
    "convertx"
    "stirling-pdf"
    "it-tools"
    "immich"
    "metube"
    "crafty"
    "omni-tools"
    "searxng"
)


# --- Functions ---

# Function to check for required commands
check_deps() {
    if ! command -v docker &> /dev/null; then
        echo -e "${C_RED}Error: docker is not installed or not in your PATH.${C_RESET}"
        exit 1
    fi
    if ! docker compose version &> /dev/null; then
        echo -e "${C_RED}Error: docker compose is not available.${C_RESET}"
        echo -e "${C_RED}Please install the Docker Compose V2 plugin.${C_RESET}"
        exit 1
    fi
}

# Function to pull and start a single Docker Compose application
start_app() {
    local app_name="$1"
    local compose_file="$2"

    if [ ! -f "$compose_file" ]; then
        echo -e "\n${C_YELLOW}Warning: docker-compose.yml for '$app_name' not found at '$compose_file'. Skipping.${C_RESET}"
        return
    fi

    echo -e "\n${C_BLUE}--- Processing $app_name ---${C_RESET}"
    echo "Checking for updates..."
    docker compose -f "$compose_file" pull
    echo "Starting $app_name..."
    docker compose -f "$compose_file" up -d
    echo -e "${C_GREEN}App $app_name started successfully.${C_RESET}"
}

# Function to start all essential apps
start_essentials() {
    echo -e "\n${C_GREEN}Starting essential apps...${C_RESET}"
    for app in "${essential_apps[@]}"; do
        start_app "$app" "$ESSENTIALS_BASE_PATH/$app/docker-compose.yml"
    done
    echo -e "\n${C_GREEN}All essential apps processed.${C_RESET}"
}

# Function to stop a single Docker Compose application
stop_app() {
    local app_name="$1"
    local compose_file="$2"

    if [ ! -f "$compose_file" ]; then
        echo -e "\n${C_GRAY}Info: docker-compose.yml for '$app_name' not found at '$compose_file'. Skipping.${C_RESET}"
        return
    fi

    echo -e "\n${C_YELLOW}--- Stopping $app_name ---${C_RESET}"
    docker compose -f "$compose_file" down
    echo -e "${C_GREEN}$app_name stopped.${C_RESET}"
}

# Reusable function to display an interactive selection menu
# Arguments: 1:Title, 2:Action Verb, 3:All Apps Array Name, 4:Selected Status Array Name
# Returns 0 on 'start/stop', 1 on 'quit'
show_selection_menu() {
    local title="$1"
    local action_verb="$2"
    local -n all_apps_ref="$3"       # Nameref to all apps array
    local -n selected_status_ref="$4" # Nameref to selection status array

    while true; do
        clear
        echo "-----------------------------------------------------"
        echo -e "${C_GREEN}${title}. Use number to toggle.${C_RESET}"
        echo "-----------------------------------------------------"
        for i in "${!all_apps_ref[@]}"; do
            if ${selected_status_ref[$i]}; then
                echo -e "$((i+1)). ${C_GREEN}[x]${C_RESET} ${all_apps_ref[$i]}"
            else
                echo -e "$((i+1)). ${C_RED}[ ]${C_RESET} ${all_apps_ref[$i]}"
            fi
        done
        echo "----------------------------------------------------"
        echo "Enter a number to toggle, (s) to ${action_verb} selected, or (q)uit."

        read -rp "Your choice: " choice

        case "$choice" in
            [sS]) return 0 ;; # Proceed
            [qQ]) return 1 ;; # Quit
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#all_apps_ref[@]}" ]; then
                    local index=$((choice-1))
                    if ${selected_status_ref[$index]}; then
                        selected_status_ref[$index]=false
                    else
                        selected_status_ref[$index]=true
                    fi
                else
                    echo -e "${C_RED}Invalid input. Press Enter to continue...${C_RESET}"
                    read -r
                fi
                ;;
        esac
    done
}

# Function to let the user select and start apps
start_selected() {
    # Pre-select apps based on the default list for easier maintenance
    declare -A default_map
    for app in "${default_selected_apps[@]}"; do
        default_map["$app"]=1
    done

    declare -a selected_status
    for app in "${all_selectable_apps[@]}"; do
        if [[ -v default_map[$app] ]]; then
            selected_status+=("true")
        else
            selected_status+=("false")
        fi
    done

    # Show menu and get user's final selection. Exit if user quits.
    if ! show_selection_menu "Select apps to start" "start" all_selectable_apps selected_status; then
        echo "Quitting without starting."
        return
    fi

    echo -e "\n${C_GREEN}Starting selected apps...${C_RESET}"
    apps_to_start=()
    for i in "${!all_selectable_apps[@]}"; do
        if ${selected_status[$i]}; then
            apps_to_start+=("${all_selectable_apps[$i]}")
        fi
    done

    if [ ${#apps_to_start[@]} -eq 0 ]; then
        echo "No apps were selected to start."
        return
    fi

    for app in "${apps_to_start[@]}"; do
        start_app "$app" "$MANAGED_BASE_PATH/$app/docker-compose.yml"
    done
    echo -e "\n${C_GREEN}All selected apps processed.${C_RESET}"
}

# Function to stop all essential apps
stop_essentials() {
    echo -e "\n${C_YELLOW}Stopping essential apps...${C_RESET}"
    for app in "${essential_apps[@]}"; do
        stop_app "$app" "$ESSENTIALS_BASE_PATH/$app/docker-compose.yml"
    done
    echo -e "\n${C_GREEN}All essential apps stopped.${C_RESET}"
}

# Function to let the user select and stop apps
stop_selected() {
    echo "Checking status of selectable apps..."
    # Use an associative array for efficient checking of running projects
    declare -A running_apps_map
    while read -r project; do
        # Ensure we don't add an empty key if there are no running containers
        [[ -n "$project" ]] && running_apps_map["$project"]=1
    done < <(docker ps --format '{{.Label "com.docker.compose.project"}}' | sort -u)

    # Pre-select apps that are currently running
    declare -a selected_status
    for app in "${all_selectable_apps[@]}"; do
        if [[ -v running_apps_map[$app] ]]; then
            selected_status+=("true")
        else
            selected_status+=("false")
        fi
    done

    # Show menu and get user's final selection. Exit if user quits.
    if ! show_selection_menu "Select apps to STOP" "stop" all_selectable_apps selected_status; then
        echo "Quitting without stopping."
        return
    fi

    apps_to_stop=()
    for i in "${!all_selectable_apps[@]}"; do
        if ${selected_status[$i]}; then
            apps_to_stop+=("${all_selectable_apps[$i]}")
        fi
    done

    if [ ${#apps_to_stop[@]} -eq 0 ]; then
        echo "No apps were selected to stop."
        return
    fi

    echo -e "\n${C_YELLOW}Stopping selected apps...${C_RESET}"
    for app in "${apps_to_stop[@]}"; do
        stop_app "$app" "$MANAGED_BASE_PATH/$app/docker-compose.yml"
    done
    echo -e "\n${C_GREEN}All selected apps processed.${C_RESET}"
}

# Function to stop all running Docker Compose projects
stop_all() {
    echo -e "\n${C_YELLOW}Stopping all running Docker Compose projects...${C_RESET}"
    # Use --quiet flag for a simple list of names, more robust than parsing.
    # The read loop handles the case where there are no projects.
    docker compose ls --quiet | while read -r project; do
        echo "Stopping Docker Compose project: $project"
        docker compose -p "$project" down --remove-orphans
    done

    echo -e "\n${C_GREEN}All Docker Compose projects have been processed.${C_RESET}"
}


# --- Main Script Logic ---
check_deps
clear
echo "============================"
echo -e "   ${C_GREEN}Docker Apps Manager${C_RESET}"
echo "============================"
PS3="Please select an option: "
options=(
    "Start ESSENTIAL apps"
    "Choose and Start SELECTED apps"
    "Stop ESSENTIAL apps"
    "Choose and Stop SELECTED apps"
    "STOP ALL RUNNING APPS"
    "Quit"
)

select opt in "${options[@]}"; do
    case $opt in
        "Start ESSENTIAL apps") start_essentials; break ;;
        "Choose and Start SELECTED apps") start_selected; break ;;
        "Stop ESSENTIAL apps") stop_essentials; break ;;
        "Choose and Stop SELECTED apps") stop_selected; break ;;
        "STOP ALL RUNNING APPS") stop_all; break ;;
        "Quit") echo "Exiting."; break ;;
        *) echo -e "${C_RED}Invalid option $REPLY${C_RESET}" ;;
    esac
done
