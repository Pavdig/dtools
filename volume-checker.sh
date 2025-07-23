#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -eo pipefail

# --- Configuration ---
DOCKER_IMAGE="docker/alpine-tar-zstd:latest"

# --- Colors ---
BLUE_BG='\033[44;37m'
YELLOW='\033[33m'
RED='\033[31m'
NC='\033[0m' # No Color

# --- Functions ---

print_header() {
    printf "${BLUE_BG}%s${NC}\n" "$1"
}

run_in_volume() {
    local volume_name="$1"
    shift
    docker run --rm -v "${volume_name}:/volume" "${DOCKER_IMAGE}" "$@"
}

# --- Main Script ---

main() {
    if ! command -v docker &> /dev/null; then
        printf "${RED}Error: docker command not found. Please ensure Docker is installed and in your PATH.${NC}\n"
        exit 1
    fi

    print_header "Docker volume checker"

    # Get all available Docker volumes into an array
    printf "\n${YELLOW}Fetching available Docker volumes...${NC}\n"
    mapfile -t volumes < <(docker volume ls --format "{{.Name}}")

    if [ ${#volumes[@]} -eq 0 ]; then
        printf "${RED}No Docker volumes found.${NC}\n"
        exit 1
    fi

    # Present a selectable list of volumes
    printf "\n${YELLOW}Please select the volume you want to check out:${NC}\n"
    local volume_name
    PS3="Enter the number for the volume: "
    select choice in "${volumes[@]}"; do
        if [[ -n "$choice" ]]; then
            volume_name="$choice"
            break
        else
            printf "${RED}Invalid selection. Please try again.${NC}\n"
        fi
    done

    printf "\n"
    print_header "Inspecting ${volume_name}..."
    docker volume inspect "${volume_name}"

    printf "\n"
    print_header "Listing files in dir..."
    run_in_volume "${volume_name}" ls -lah /volume

    printf "\n"
    print_header "Calculating total size of the volume '${volume_name}'..."
    run_in_volume "${volume_name}" du -sh /volume
    printf "\n"
}

main "$@"
