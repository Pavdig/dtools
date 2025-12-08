# Docker Tool Suite (dtools)

A Bash script with a Text User Interface (TUI) to simplify managing Docker Compose applications, backups, and updates on Linux servers.

## 🚀 Features

- **App Management:** Start, stop, restart, and force recreate containers. Includes an update checker to only recreate changed images.
- **Backups:** Auto-detects and backs up volumes for specific apps or standalone volumes. Supports `zstd` compression and **AES-256 encrypted** `7-Zip` archives using a secure local key.
- **Automation:** Built-in scheduler (Cron) for automatic app updates and cleaning up unused images.
- **Maintenance:**  View logs, inspect image healthchecks, prune system (unused containers/networks), and manage local image history for rollbacks.
- **Safety:** Includes "Dry Run" modes and validates configuration inputs (paths, integers) to prevent errors.

## 🛠️ Installation

1. **Clone the repo:**
   ```bash
   git clone https://github.com/Pavdig/dtools.git
   cd dtools
2. **Make executable:**
   ```bash
   chmod +x docker_tool_suite.sh
   ```

3. **Run:**
   ```bash
   ./docker_tool_suite.sh
   ```
   *The script will auto-install dependencies (openssl, 7zip) and guide you through the initial setup wizard.*

## 📖 Usage

**Interactive Mode:**
Run with sudo to access the menu:
```bash
sudo ./docker_tool_suite.sh
# or if you set up the default alias:
dtools
```

**CLI (Cron) Mode:**
```bash
# Update all apps
sudo ./docker_tool_suite.sh update --cron

# Clean unused images
sudo ./docker_tool_suite.sh update-unused --cron
```

## 📂 Configuration

Settings are stored in `~/.config/dtools/config.conf`.
You can change paths, retention policies, and helper images directly inside the script via **Settings Manager** in the main menu.