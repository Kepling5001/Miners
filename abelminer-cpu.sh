#!/bin/bash

set -euo pipefail

# Some constants to setup

# Systemd service name
SERVICE_NAME="abe-mining-cpu-client.service"

# the miner executable, should be in the same directory as this script
EXECUTABLE_NAME="abelminer-cpu"
# download directory and tar extraction directory
DOWNLOAD_DIR_NAME="abe-miningpool-client-linux"


# systemd service files directory
SERVICE_FILE_PATH="/etc/systemd/system/${SERVICE_NAME}"

# show usage
usage() {
    echo "Usage: $0 <start|stop|status> [arch] [username] [password]"
    echo "  start   <arch> <username> <password> : Download, install and start cpu miner service. arch can be 'amd64' or 'arm64'"
    echo "  stop                   : stop cpu miner service"
    echo "  status                 : check cpu miner service status"
    exit 1
}

# check command exists
command_exists() {
    command -v "$1" &> /dev/null
}


if [ "$#" -lt 1 ]; then
    usage
fi

ACTION=$1

case "$ACTION" in
    start)
        if [ "$#" -ne 4 ]; then
            echo "error: 'start' should provide arch, username and password"
            usage
        fi

        ARCH=$2
        USERNAME=$3
        PASSWORD=$4

        if [[ "$ARCH" != "amd64" && "$ARCH" != "arm64" ]]; then
            echo "error: invalid arch specified. Must be 'amd64' or 'arm64'"
            usage
        fi

        DOWNLOAD_URL="https://download.pqabelian.io/release/pool/abelminer-cpu-linux-${ARCH}-v0.13.2.tar.gz"

        REAL_USER="${SUDO_USER:-$(whoami)}"
        USER_HOME=$(eval echo "~$REAL_USER")

        EXTRACT_DIR="${USER_HOME}/${DOWNLOAD_DIR_NAME}"
        EXECUTABLE_PATH="${EXTRACT_DIR}/${EXECUTABLE_NAME}"

        echo "CPU miner client directory: ${EXECUTABLE_PATH}"

        if [ ! -f "$EXECUTABLE_PATH" ]; then
            echo "'${EXECUTABLE_PATH}' not found, try to download..."

            if ! command_exists wget; then
                echo "error: 'wget' not found, please install wget (e.g., sudo apt install wget)"
                exit 1
            fi
            if ! command_exists tar; then
                echo "error: 'tar' not found, please install tar (e.g., sudo apt install tar)"
                exit 1
            fi

            TMP_DIR=$(mktemp -d)
            echo "Downloading CPU miner client to ${TMP_DIR}..."

            sudo wget -q --show-progress -O "${TMP_DIR}/client.tar.gz" "$DOWNLOAD_URL"

            echo "Extracting CPU miner client to ${EXTRACT_DIR}..."

            sudo mkdir -p "$EXTRACT_DIR"

            sudo tar -xzf "${TMP_DIR}/client.tar.gz" -C "$EXTRACT_DIR" --strip-components=1

            sudo rm -rf "$TMP_DIR"

            sudo chown -R "$REAL_USER:$REAL_USER" "$EXTRACT_DIR"

        else
            echo "CPU miner client exists in '${EXTRACT_DIR}'"
        fi

        if [ ! -f "$EXECUTABLE_PATH" ]; then
            echo "error: '${EXECUTABLE_PATH}' still not found after download"
            exit 1
        fi
        if [ ! -x "$EXECUTABLE_PATH" ]; then
            echo "'${EXECUTABLE_PATH}' is not executable, try to change file mode..."
            chmod +x "$EXECUTABLE_PATH"
        fi

        if [ -f "$SERVICE_FILE_PATH" ]; then
            sudo rm -f "$SERVICE_FILE_PATH"
        fi
        echo "Creating new service file..."

        sudo tee "$SERVICE_FILE_PATH" > /dev/null <<EOF
[Unit]
Description=ABEL CPU Mining Pool Client Service
After=network.target

[Service]
User=${REAL_USER}
Group=${REAL_USER}
WorkingDirectory=${EXTRACT_DIR}
ExecStart=${EXECUTABLE_PATH} -u "${USERNAME}" -p "${PASSWORD}" --logdir="${EXTRACT_DIR}"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

        echo "Reloading systemd daemon..."
        sudo systemctl daemon-reload
        echo "Enabling service on system boot..."
        sudo systemctl enable "$SERVICE_NAME"

        echo "Starting '${SERVICE_NAME}'..."
        sudo systemctl start "$SERVICE_NAME"
        sleep 1
        sudo systemctl status "$SERVICE_NAME"
        ;;

    stop)
        echo "Stopping '${SERVICE_NAME}'..."
        sudo systemctl stop "$SERVICE_NAME"
        ;;

    status)
        echo "Checking '${SERVICE_NAME}' status..."
        sudo systemctl status "$SERVICE_NAME"
        ;;

    *)
        echo "error: invalid operation '$ACTION'。"
        usage
        ;;
esac

exit 0
