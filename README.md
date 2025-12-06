# Docker Tool Suite (dtools)

A powerful, self-hosted Bash script designed to simplify the management of Docker Compose applications on Linux servers. It provides a Text User Interface (TUI) to handle updates, backups, logs, and system maintenance without needing to remember complex Docker commands.

## 🚀 Features

### 🐳 Application Management
- **Interactive Control:** Start, Stop, and Restart essential or managed app stacks.
- **Smart Updates:** Checks for image hash changes before recreating containers.
- **Rollback System:** Keeps a local history of image IDs, allowing you to quickly rollback an application to a previous version if an update fails.
- **Force Recreate:** Option to force container recreation (useful for config changes).
- **Interactive Error Recovery:** Automatically detects invalid Docker Compose configurations and prompts you to edit and fix them on the fly.

### 💾 Volume & Backup Manager
- **Smart Backups:** Automatically detects which volumes belong to which application. Stops the app, backs up the volume, and restarts the app to ensure data consistency.
- **Standalone Backups:** Detects and backs up volumes not attached to specific projects.
- **Secure Archives:** Compresses backups using `tar` + `zstd`. Optionally creates encrypted, password-protected 7-Zip archives (AES-256, split-volume supported).
- **Volume Explorer:** Mounts a volume into a temporary interactive shell to inspect files without attaching to the main container.
- **Restore Wizard:** Easily restore volumes from previous backups.

### ⚙️ Automation & Utilities
- **Shell Integration:** Easily create and manage a `dtools` alias for your shell (`.bashrc`/`.zshrc`) to run the tool from anywhere.
- **Cron Integration:** Built-in scheduler for automatic app updates and unused image cleanup.
- **Log Management:** Centralized log viewer with auto-pruning (retention policies).
- **System Prune:** Guided clean-up of stopped containers, unused networks, and build caches.
- **Security:** Encrypts sensitive configuration passwords (like RAR passwords) using a machine-specific key (OpenSSL).
- **Smart Setup:** Auto-detects missing dependencies and corrupted configurations, offering self-repair and auto-installation of tools like `openssl` and `7z`.

## 📋 Prerequisites

The script runs on Debian-based systems. It automatically checks for required tools and offers to install them if missing:
- **Docker** & **Docker Compose V2**
- `openssl` (Required for password encryption)
- `p7zip-full` (Optional, for creating secure archives)
- Root/Sudo privileges (Script will prompt for password if not run as root)

## 🛠️ Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/Pavdig/dtools.git
   cd dtools
   ```

2. Make the script executable:
   ```bash
   chmod +x docker_tool_suite.sh
   ```

3. Run the script:
   ```bash
   ./docker_tool_suite.sh
   # The script will prompt for sudo password if required.
*On the first run, the script will guide you through a setup wizard to define your app directories, backup locations, retention policies, and optional shell shortcuts.*

## 📖 Usage

### Interactive Mode (TUI)
Simply run the script with sudo (or use your configured alias) to access the main menu:
```bash
sudo ./docker_tool_suite.sh
# OR if alias is configured:
sudo dtools
```

### CLI / Cron Mode
The script supports non-interactive flags for scheduled tasks:

- **Update all apps:**
  ```bash
  sudo ./docker_tool_suite.sh update --cron
  ```
- **Clean unused images:**
  ```bash
  sudo ./docker_tool_suite.sh update-unused --cron
  ```
- **Dry Run (Simulation):**
  ```bash
  sudo ./docker_tool_suite.sh update --dry-run
  ```

## 📂 Configuration

Configuration is stored securely in `~/.config/dtools/config.conf`. You can change settings (paths, ignored volumes, helper images) directly via the **Utilities > Manage Settings** menu inside the script.

**Safe Reset:** If you make a mistake while editing a setting (like a helper image tag), simply type `reset` when prompted to revert that setting to its original default value.

## ⚠️ Disclaimer
This tool performs operations that modify your Docker containers and volumes. While it includes safety checks (like dry-runs and confirmations), always ensure you have valid backups before performing system prunes or volume restorations.