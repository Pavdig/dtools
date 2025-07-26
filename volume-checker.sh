#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error when substituting.
# Pipelines return the exit status of the last command to fail.
set -euo pipefail

# --- Configuration ---
DOCKER_IMAGE="docker/alpine-tar-zstd:latest"

# --- Colors ---
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NOCOLOR=$'\033[0m' # No Color

# --- Functions ---

# Function to handle script interruption
cleanup() {
    printf "\n\n%s\n" "${YELLOW}Script interrupted. Exiting.${NOCOLOR}"
    exit 130 # Standard exit code for Ctrl+C
}

# Trap SIGINT (Ctrl+C) and SIGTERM to run the cleanup function
trap cleanup SIGINT SIGTERM

print_header() {
    printf "\n${BLUE}--- %s ---${NOCOLOR}\n" "$1"
}

# Function to ensure the required Docker image is available
ensure_docker_image() {
    printf "%s" "-> " # Print arrow separately to avoid issues with printf options
    printf "Checking for Docker image: ${BLUE}%s${NOCOLOR}...\n" "${DOCKER_IMAGE}"
    if ! docker image inspect "${DOCKER_IMAGE}" &> /dev/null; then
        printf "%s\n" "   -> Image not found locally. Pulling from Docker Hub..."
        if ! docker pull "${DOCKER_IMAGE}"; then
            printf "${RED}Error: Failed to pull Docker image '%s'. Please check your internet connection and Docker setup.${NOCOLOR}\n" "${DOCKER_IMAGE}"
            exit 1
        fi
    fi
    printf "%s\n" "-> ${GREEN}Image OK.${NOCOLOR}"
}

run_in_volume() {
    local volume_name="$1"
    shift
    # Mount volume as read-only (:ro) to prevent accidental changes
    docker run --rm -v "${volume_name}:/volume:ro" "${DOCKER_IMAGE}" "$@"
}

inspect_and_display_volume_info() {
    local volume_name="$1"
    print_header "Inspecting '${volume_name}'"
    docker volume inspect "${volume_name}"

    print_header "Listing files in '${volume_name}'"
    run_in_volume "${volume_name}" ls -lah /volume

    print_header "Calculating total size of '${volume_name}'"
    run_in_volume "${volume_name}" du -sh /volume
}

explore_volume() {
    local volume_name="$1"
    print_header "Interactive Shell for '${volume_name}'"
    printf "%s\n" "${YELLOW}The volume '${volume_name}' is mounted read-write at /volume."
    printf "%s\n" "Type 'exit' or press Ctrl+D to return to the menu.${NOCOLOR}"
    # -it: interactive tty
    # -w: set working directory
    # mount rw for interactive use
    docker run --rm -it -v "${volume_name}:/volume" -w /volume "${DOCKER_IMAGE}" sh
}

remove_volume() {
    local volume_name="$1"
    local confirm
    printf "\n"
    # Use -r to prevent backslash interpretation and printf to allow colors in the prompt
    read -r -p "$(printf "${YELLOW}Are you sure you want to permanently delete volume '${BLUE}%s${YELLOW}'? [y/N]: ${NOCOLOR}" "${volume_name}")" confirm
    printf "\n"

    if [[ "${confirm}" =~ ^[yY]([eE][sS])?$ ]]; then
        printf "%s\n" "-> Deleting volume '${volume_name}'..."
        if docker volume rm "${volume_name}"; then
            printf "%s\n" "${GREEN}Volume successfully deleted.${NOCOLOR}"
            sleep 2
            return 0 # Success
        else
            printf "%s\n" "${RED}Error: Failed to delete volume '${volume_name}'. It might be in use.${NOCOLOR}"
            sleep 3
            return 1 # Failure
        fi
    else
        printf "%s\n" "-> Deletion cancelled.${NOCOLOR}"
        sleep 1
        return 1 # Cancelled
    fi
}

manage_volume() {
    local volume_name="$1"

    # Action Menu Loop
    while true; do
        clear
        inspect_and_display_volume_info "${volume_name}"

        print_header "Actions for '${volume_name}'"
        printf "%s\n" "${YELLOW}What would you like to do?${NOCOLOR}"
        PS3="Enter action number: "
        local options=("Return to volume list" "Explore volume (interactive shell)" "Remove volume" "Quit")
        select action in "${options[@]}"; do
            case "$action" in
                "Return to volume list")
                    return # Emerge from this function, back to the main volume list
                    ;;
                "Explore volume (interactive shell)")
                    explore_volume "${volume_name}"
                    break # Redraw action menu
                    ;;
                "Remove volume")
                    # If removal is successful, return to the main list to see the updated state
                    if remove_volume "${volume_name}"; then return; fi
                    break # If removal fails or is cancelled, just redraw the action menu
                    ;;
                "Quit") exit 0 ;;
                *) printf "%s\n" "${RED}Invalid option '$REPLY'${NOCOLOR}"; sleep 1; break ;;
            esac
        done
    done
}

# --- Main Script ---

main() {
    clear
    printf "%s\n" "${GREEN}_--| Docker Volume Checker |---_${NOCOLOR}"

    if ! command -v docker &> /dev/null; then
        printf "\n%s\n" "${RED}Error: docker command not found. Please ensure Docker is installed and in your PATH.${NOCOLOR}"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        printf "\n%s\n" "${RED}Error: Could not connect to the Docker daemon. Is it running?${NOCOLOR}"
        printf "%s\n" "${YELLOW}You may need to run this script with 'sudo' or add your user to the 'docker' group.${NOCOLOR}"
        exit 1
    fi

    ensure_docker_image

    while true; do
        clear
        printf "%s\n" "${GREEN}_--| Docker Volume Checker |---_${NOCOLOR}"
        # Get all available Docker volumes into an array
        print_header "Fetching available Docker volumes"
        mapfile -t volumes < <(docker volume ls --format "{{.Name}}")

        if [ ${#volumes[@]} -eq 0 ]; then
            printf "%s\n" "${YELLOW}No Docker volumes found.${NOCOLOR}"
            exit 0
        fi

        # Present a selectable list of volumes
        printf "\n%s\n" "${YELLOW}Please select a volume to manage:${NOCOLOR}"
        PS3=$'\n'"Enter number (or Ctrl+C to exit): "
        select volume_name in "${volumes[@]}"; do
            if [[ -n "$volume_name" ]]; then
                manage_volume "${volume_name}"
                # After manage_volume returns, break from the select loop
                # to force the outer while loop to re-run and refresh the volume list.
                break
            else
                printf "%s\n" "${RED}Invalid selection. Please try again.${NOCOLOR}";
            fi
        done
    done # End of main while loop
}

main "$@"
