#!/bin/bash

# --- Configuration ---

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipelines return the exit status of the last command to fail.
set -o pipefail

# --- Cosmetics ---

# Display colors
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NOCOLOR=$'\033[0m'
TICKMARK=$'\033[0;32m\xE2\x9C\x93' # GREEN ✓

# --- User Detection ---

# Get the username of the user who invoked sudo, or fallback to the current user.
# This makes the default paths user-specific.
if [[ -n "${SUDO_USER-}" ]]; then
    CURRENT_USER="${SUDO_USER}"
else
    CURRENT_USER="${USER:-$(whoami)}"
fi

# --- Script Default Variables ---

# Default backup location using the detected user's home directory.
defaultBackupDir="/home/${CURRENT_USER}/backups/volume-backups/$(date +'%Y-%m-%d_%H-%M-%S')/"

# Default restore location using the detected user's home directory.
defaultRestoreDir="/home/${CURRENT_USER}/backups/restore-folder"

# List of Docker volumes to ignore during backup.
ignoreVolumes=(
        "immich_model-cache"
        "ollama_data"
        "languagetool_ngrams"
)

# Docker image for backup and restore tasks
DOCKER_IMAGE="docker/alpine-tar-zstd:latest"

# --- Helper Functions ---

# Function to clear the terminal and display a welcome message
welcome_message() {
    clear
    echo -e "\n${GREEN}_--| Docker Volume Backup & Restore Utility |---_${NOCOLOR}\n"
}

# Function to handle script interruption
cleanup() {
    printf "\n\n%sScript interrupted. Cleaning up...%s\n" "${RED}" "${NOCOLOR}"
    local containers_to_stop
    containers_to_stop=$(docker ps -q --filter "label=backup-script-pid=$$")

    if [[ -n "$containers_to_stop" ]]; then
        printf "%sStopping backup container(s)...%s\n" "${YELLOW}" "${NOCOLOR}"
        docker stop "$containers_to_stop" > /dev/null
        echo -e "${GREEN}Cleanup complete.${NOCOLOR}"
    fi
    exit 1
}

# Trap SIGINT (Ctrl+C) and SIGTERM to run the cleanup function
trap cleanup SIGINT SIGTERM

# Function to ensure the required Docker image is available
ensure_docker_image() {
    echo -e "-> Checking for Docker image: ${BLUE}${DOCKER_IMAGE}${NOCOLOR}..."
    if ! docker image inspect "${DOCKER_IMAGE}" &> /dev/null; then
        echo "   -> Image not found locally. Pulling from Docker Hub..."
        if ! docker pull "${DOCKER_IMAGE}"; then
            echo -e "${RED}Error: Failed to pull Docker image '${DOCKER_IMAGE}'. Please check your internet connection and Docker setup.${NOCOLOR}"
            exit 1
        fi
    fi
    echo -e "-> Image OK.\n"
}

# --- Backup Functions ---

backup_main() {
    welcome_message
    echo -e "${GREEN}Starting Docker Volume Backup...${NOCOLOR}"

    # Check if the script is run as root
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}This script must be run as root to interact with the Docker daemon. Please use 'sudo'.${NOCOLOR}"
       exit 1
    fi

    # Get a list of all Docker volumes
    mapfile -t volumes < <(docker volume ls --format "{{.Name}}")

    # Filter out ignored volumes
    local filteredVolumes=()
    for volume in "${volumes[@]}"; do
        if [[ ! " ${ignoreVolumes[*]} " =~ " ${volume} " ]]; then
            filteredVolumes+=("$volume")
        fi
    done

    # Pre-selection of volumes
    local selected=()
    while true; do
        echo -e "${BLUE}Do You want to preselect all available volumes?${YELLOW}"
        echo -e "Type 'Quit'/'Q' to cancel the process.${BLUE}"
        read -p "(Yes-Y/No-N): " select_all
        select_all=$(echo "$select_all" | tr '[:upper:]' '[:lower:]')

        if [[ "$select_all" == "yes" || "$select_all" == "y" ]]; then
            for _ in "${filteredVolumes[@]}"; do selected+=(1); done
            break
        elif [[ "$select_all" == "no" || "$select_all" == "n" ]]; then
            for _ in "${filteredVolumes[@]}"; do selected+=(0); done
            break
        elif [[ "$select_all" == "quit" || "$select_all" == "q" ]]; then
            echo -e "\n${RED}Process canceled!${NOCOLOR}\n"
            exit 0
        else
            welcome_message
            echo -e "${RED}Please choose a valid option!${NOCOLOR}\n"
            sleep 1
        fi
    done

    # Toggle selection of volumes
    while true; do
        welcome_message
        echo -e "${YELLOW}Toggle the selection of volumes by entering the corresponding number:${NOCOLOR}\n"
        local i
        for i in "${!filteredVolumes[@]}"; do
            if [[ ${selected[$i]} -eq 1 ]]; then
                echo -e "   ${NOCOLOR}[${BLUE}$i${NOCOLOR}] [${TICKMARK}${NOCOLOR}] ${YELLOW}- ${GREEN}${filteredVolumes[$i]}${NOCOLOR}"
            else
                echo -e "   ${NOCOLOR}[${BLUE}$i${NOCOLOR}] [${RED}X${NOCOLOR}] ${YELLOW}- ${RED}${filteredVolumes[$i]}${NOCOLOR}"
            fi
        done

        echo -e "\n${YELLOW}Enter a ${NOCOLOR}[${BLUE}number${NOCOLOR}] ${YELLOW}of a volume to toggle the selection,"
        echo -e "and then press the ENTER key to confirm.${GREEN}"
        read -p "Or press ENTER to continue with the current selection: " input

        if [[ -z $input ]]; then
            break
        fi

        if [[ $input =~ ^[0-9]+$ ]] && (( input >= 0 && input < ${#filteredVolumes[@]} )); then
            if [[ ${selected[$input]} -eq 1 ]]; then
                selected[$input]=0
            else
                selected[$input]=1
            fi
        else
            echo -e "${RED}Invalid input. Please enter a number from the list.${NOCOLOR}"
            sleep 1
        fi
    done

    # Create a new list with selected volumes
    local selectedVolumes=()
    for i in "${!filteredVolumes[@]}"; do
        if [[ ${selected[$i]} -eq 1 ]]; then
            selectedVolumes+=("${filteredVolumes[$i]}")
        fi
    done

    if [[ ${#selectedVolumes[@]} -eq 0 ]]; then
        echo -e "\n${RED}No volumes selected! Exiting...${NOCOLOR}\n"
        exit 0
    fi

    # Set backup directory
    local backupDir
    echo -e "\n${YELLOW}The current default backup location is: ${NOCOLOR}"
    echo -e "${GREEN}'$defaultBackupDir'${NOCOLOR}\n"
    read -p "Do you want to change it? (Yes/Y or press Enter to skip): " changeDirResponse
    changeDirResponse=$(echo "$changeDirResponse" | tr '[:upper:]' '[:lower:]')
    if [[ "$changeDirResponse" == "yes" || "$changeDirResponse" == "y" ]]; then
        while true; do
            read -p "Enter new backup path (or 'Q' to quit): " customBackupDir
            if [[ "$(echo "$customBackupDir" | tr '[:upper:]' '[:lower:]')" == "q" ]]; then
                echo -e "\n${RED}Process canceled!${NOCOLOR}\n"
                exit 0
            fi
            if [[ ! "$customBackupDir" =~ ^/ ]]; then
                echo -e "${RED}Invalid path. Path must be absolute (start with '/').${NOCOLOR}"
                continue
            fi
            [[ "${customBackupDir: -1}" != "/" ]] && customBackupDir+="/"
            if [[ -d "$customBackupDir" ]]; then
                if [[ -n "$(ls -A "$customBackupDir" 2>/dev/null)" ]]; then
                    echo -e "${YELLOW}Directory ${BLUE}'$customBackupDir'${YELLOW} is not empty. Files may be overwritten.${NOCOLOR}"
                    read -p "Use this directory anyway? (y/N): " useNotEmptyDir
                    if [[ "$(echo "$useNotEmptyDir" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
                        backupDir="$customBackupDir"
                        break
                    fi
                else
                    backupDir="$customBackupDir"
                    break
                fi
            else
                if mkdir -p "$customBackupDir"; then
                    echo -e "${GREEN}Created directory: ${BLUE}$customBackupDir${NOCOLOR}"
                    backupDir="$customBackupDir"
                    break
                else
                    echo -e "${RED}Could not create directory: ${BLUE}$customBackupDir${NOCOLOR}"
                fi
            fi
        done
    else
        backupDir="$defaultBackupDir"
    fi

    # Confirmation
    echo -e "\n${BLUE}#${GREEN}${#selectedVolumes[@]} ${BLUE}Docker Volume/s selected for backup:${NOCOLOR}"
    for volume in "${selectedVolumes[@]}"; do
        echo -e "${GREEN}$volume ${NOCOLOR}"
    done
    echo -e "\n${YELLOW}Backup directory set to: ${BLUE}$backupDir${NOCOLOR}\n"
    read -p "Type 'Yes'/'y' to continue or press 'Enter' to cancel: " response
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]')

    if [[ "$response" == "y" || "$response" == "yes" ]]; then
        [[ ! -d "$backupDir" ]] && mkdir -p "$backupDir"
        local totalVolumes=${#selectedVolumes[@]}
        local currentVolumeIndex=1
        for volume in "${selectedVolumes[@]}"; do
            echo -e "${BLUE}$currentVolumeIndex${NOCOLOR}/${BLUE}$totalVolumes - ${YELLOW}Backing up ${BLUE}$volume${NOCOLOR}..."
            docker run --rm --label "backup-script-pid=$$" -v "${volume}:/volume:ro" -v "${backupDir}:/backup" "${DOCKER_IMAGE}" tar -C /volume -zcvf "/backup/${volume}.tar.gz" .
            echo -e "${YELLOW}Backup of ${BLUE}$volume ${YELLOW}created successfully.${NOCOLOR}"
            ((currentVolumeIndex++))
        done
        if [[ -n "$SUDO_USER" ]]; then
            echo -e "${YELLOW}Changing ownership of backup files to user '$SUDO_USER'...${NOCOLOR}"
            chown -R "$SUDO_USER:$SUDO_GID" "$backupDir"
        else
            echo -e "${YELLOW}WARNING: SUDO_USER not set. Applying broad permissions (777).${NOCOLOR}"
            chmod -R 777 "$backupDir"
        fi
        echo -e "${BLUE}Saved file location:\n${YELLOW}$backupDir${NOCOLOR}\n"
    else
        echo -e "${RED}Backup has been canceled!${NOCOLOR}\n"
        exit 1
    fi
    echo -e "${GREEN}_--All tasks completed!--_${NOCOLOR}\n"
}

# --- Restore Functions ---

restore_main() {
    welcome_message
    echo -e "${GREEN}Starting Docker Volume Restore...${NOCOLOR}"
    ensure_docker_image

    local backupFiles=()
    local backupDir
    while [ ${#backupFiles[@]} -eq 0 ]; do
        echo -e "${YELLOW}The current restore directory is set to: '${GREEN}$defaultRestoreDir${YELLOW}'.${NOCOLOR}"
        read -p "Type ('yes'/'y') to change it or press 'Enter' to skip: " changeDir
        if [[ "$changeDir" =~ ^(y|yes)$ ]]; then
            while true; do
                echo -e "\n${YELLOW}Please enter the full path to the restore directory.${NOCOLOR}"
                read -p "Path: " userBackupDir
                userBackupDir="${userBackupDir%/}"
                if [ -d "$userBackupDir" ]; then
                    backupDir="$userBackupDir"
                    break
                else
                    echo -e "${RED}Invalid or non-existent directory path!${NOCOLOR}"
                fi
            done
        else
            backupDir="$defaultRestoreDir"
        fi

        echo -e "\n${YELLOW}Using restore directory: '${GREEN}$backupDir${YELLOW}'.${NOCOLOR}"
        mapfile -t backupFiles < <(find "$backupDir" -type f \( -name "*.tar.gz" -o -name "*.tar" -o -name "*.zip" \) 2>/dev/null)
        if [ ${#backupFiles[@]} -eq 0 ]; then
            echo -e "${RED}No backup files found in the directory!${NOCOLOR}\n"
        fi
    done

    echo -e "${YELLOW}The following volumes will be restored:${NOCOLOR}"
    for file in "${backupFiles[@]}"; do
        local baseName
        baseName="$(basename "$file")"
        local volumeName="${baseName%%.*}"
        echo -e " ${BLUE}-> ${GREEN}${volumeName}${NOCOLOR} (from ${baseName})"
    done
    echo -e "\n${RED}This will overwrite existing data in volumes with the same name!${NOCOLOR}"
    read -p "Are you sure you want to restore these volumes? (y/yes or n/no): " confirmRestore

    if [[ "$confirmRestore" =~ ^(y|yes)$ ]]; then
        for backupFile in "${backupFiles[@]}"; do
            local baseName
            baseName="$(basename "$backupFile")"
            local volumeName="${baseName%%.*}"
            local composeName="${volumeName%%_*}"
            local volumeComposeName="${volumeName#*_}"
            local relativePath="${backupFile#$backupDir/}"
            local restoreCmd=""

            case "$baseName" in
                *.tar.gz|*.tar)
                    restoreCmd="tar -C /target/ -xvf /backup/\"${relativePath}\" --strip 1"
                    ;;
                *.zip)
                    restoreCmd="unzip -o -d /target/ /backup/\"${relativePath}\""
                    ;;
                *)
                    echo -e "\n${YELLOW}Skipping unsupported file type: ${baseName}${NOCOLOR}"
                    continue
                    ;;
            esac

            echo -e "\n${YELLOW}Restoring backup from ${BLUE}${baseName}${YELLOW} to volume ${BLUE}${volumeName}${YELLOW}...${NOCOLOR}"
            echo -e " -> Ensuring volume ${BLUE}${volumeName}${NOCOLOR} exists..."
            if ! docker volume inspect "$volumeName" &>/dev/null; then
                echo -e "    -> Volume does not exist. Creating..."
                docker volume create "$volumeName" --label com.docker.compose.project="$composeName" --label com.docker.compose.volume="$volumeComposeName"
            else
                echo -e "    -> Volume already exists. Data will be overwritten as confirmed."
            fi
            echo -e " -> Importing data..."
            docker run --rm -v "${volumeName}:/target" -v "${backupDir}:/backup" "${DOCKER_IMAGE}" sh -c "${restoreCmd}"
            echo -e "\n${GREEN}Restore for volume ${BLUE}${volumeName}${GREEN} completed.${NOCOLOR}"
        done
        echo -e "\n${GREEN}_--Restore process completed!--_${NOCOLOR}\n"
    else
        echo -e "\n${RED}Restoring has been canceled!${NOCOLOR}\n"
    fi
}

# --- Main Menu ---

main_menu() {
    while true; do
        welcome_message
        echo -e "${YELLOW}Please choose an option:${NOCOLOR}"
        echo -e "  ${BLUE}1)${NOCOLOR} Backup Docker Volumes"
        echo -e "  ${BLUE}2)${NOCOLOR} Restore Docker Volumes"
        echo -e "  ${BLUE}3)${NOCOLOR} Exit"
        read -p "Enter your choice [1-3]: " choice

        case $choice in
            1)
                backup_main
                break
                ;;
            2)
                restore_main
                break
                ;;
            3)
                echo -e "\n${GREEN}Exiting...${NOCOLOR}\n"
                exit 0
                ;;
            *)
                echo -e "\n${RED}Invalid option. Please try again.${NOCOLOR}"
                sleep 1
                ;;
        esac
    done
}

# --- Script Execution ---

main_menu
exit 0
