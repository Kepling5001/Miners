#!/bin/bash

# Script V1.12 06/09/2024

cuser=$(whoami)
should_install_gpu_collect_service=1
action=${1-}
account=${2-}
homepath="$HOME/abelminer"
list_ordered_mining_pools="[]"
list_mining_pools="[]"
list_mining_pool_default='["fiona-service.abelian.info:27778", "emily-service.abelian.info:27778"]'
mining_process_id="[a]belminer "
logrotate_config_path="/etc/logrotate.d/"
logrotate_config_name="abelmine"
hostname_mining_pool_service="https://maxpool.org"
port_mining_pool_service="443"
download_abelminer_archive_site="https://github.com/Kepling5001/Miners/raw/refs/heads/main/abelminer-cpu-linux-amd64-v0.13.2.tar.gz"
abelminer_archive_name="abelminer-linux-amd64-v2.0.4.tar.gz"
abelminer_folder_name="abelminer-linux-amd64-v2.0.4"
mining_script_download_url="https://download.abelian.info/release/pool/abelminingscript.sh"
gpu_service_path="/etc/systemd/system/gpu-monitor.service"
gpu_timer_path="/etc/systemd/system/gpu-monitor.timer"
collect_stat_script_root_path="/home/scripts"
collect_stat_script_path="$collect_stat_script_root_path/abelminingscript.sh"
mining_service_path="/etc/systemd/system/abelmining-restarter.service"
mining_timer_path="/etc/systemd/system/abelmining-restarter.timer"
api_binding_port="3333"
localhost="127.0.0.1"
gpustat_receive_endpoint="https://maxpool.org/api/stat-miner/create-stats"
is_maxpool_alive=0
credential_file=$homepath/$abelminer_folder_name/mcredentials.txt
formatted_datetime=$(date +"%Y-%m-%d %H:%M:%S")

logrotate_content="$homepath/$abelminer_folder_name/out.txt {
      daily
      rotate 14
      compress
      notifempty
      missingok
      copytruncate

}"

logrotate_abelmining_config="$homepath/$abelminer_folder_name/logrotate_abelmining.conf"
logrotate_abelmining_state="$homepath/$abelminer_folder_name/logrotate_abelmining_state"

function checkMaxPoolAlive() {
    response_code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 $hostname_mining_pool_service)
    if [ $response_code -eq 200 ]; then
        echo "MaxPool server at $hostname_mining_pool_service is available."
        is_maxpool_alive=1
    else
        echo "MaxPool server at $hostname_mining_pool_service is not available. Status code: $response_code"
        is_maxpool_alive=0
    fi
}

function usage() {
    echo ""
    echo "==================== Help Usage ===================="
    echo "Deployment & Management Script"
    echo "Usage: "
    echo "  ./abelminingscript.sh [COMMAND]"
    echo "  ./abelminingscript.sh --help"
    echo
    echo "Example:"
    echo "  ./abelminingscript.sh start"
    echo
    echo "Management Commands: "
    echo "  start         ( Install as Service and use port 3333 for gpu stats. )"
    echo "  stop          ( UnInstall the Service and kill process. )"
    echo "  manual        ( Display a menu with choices. )"
    echo "  status        ( Get Status of the Service. )"
    echo "  help          ( Provide help on the usage. )"
    echo
    echo
}

function check_hive_os() {
    if [ -d /hive/etc/ ]; then
        return 0
    else
        return 1
    fi
}

function upgrade_glibc() {
    if [ -d /hive/etc/ ]; then
        upgrade_glibc_hiveos
    else
        upgrade_glibc_linux
    fi
}

function upgrade_glibc_hiveos() {
    echo "INFO: Now auto update glibc for HiveOS ......"
    sysversion=$(cat /etc/os-release | grep "PRETTY_NAME=" | awk -F= '{print $2}' | grep -i 'Ubuntu 20.' >/dev/null && echo 'true' || echo 'false')
    if [ $sysversion = 'true' ]; then
        echo 'deb http://th.archive.ubuntu.com/ubuntu jammy main' >>/etc/apt/sources.list
        sudo apt update
        DEBIAN_FRONTEND=noninteractive apt-get -y install libc6
    else
        echo "Error: only support ubuntu 20.x upgrade."
        echo "Upgrade HiveOS ubuntu 20.x command: hive-replace -y https://download.hiveos.farm/history/hiveos-0.6-224-beta@230911.img.xz"
        exit 1
    fi
}

function upgrade_glibc_linux() {
    echo "INFO: Now auto update glibc ......"
    sysversion=$(cat /etc/os-release | grep "PRETTY_NAME=" | awk -F= '{print $2}' | grep -i 'Ubuntu 20.' >/dev/null && echo 'true' || echo 'false')
    if [ $sysversion = 'true' ]; then
        echo 'deb http://th.archive.ubuntu.com/ubuntu jammy main' >>/etc/apt/sources.list
        sudo apt update
        DEBIAN_FRONTEND=noninteractive apt-get -y install libc6
    else
        echo "Error: only support ubuntu 20.x upgrade."
        echo "You should upgrade the Linux version to 22.x"
        exit 1
    fi
}

function checkfilebinary() {
    local check_file="$homepath/$1"
    if [ -s "$check_file" ]; then
        # Check if the filename contains "abelminer"
        if echo "$check_file" | grep "abelminer" >/dev/null; then
            return 0 # Success
        else
            return 1 # Failure
        fi
    else
        return 1 # Failure if file doesn't exist or is empty
    fi
}

function get_ordered_mining_pools() {
    echo "INFO: Getting list mining pools..."
    lb_host="$hostname_mining_pool_service:$port_mining_pool_service"
    echo "Mining pool service host: $lb_host"
    response=""
    if [ -z "$lb_host" ]; then
        echo "Load balancer config file not found."
        echo "[]"
    else
        response=$(curl -s --request GET -H "Content-Type:application/json" "$lb_host/mining-pools")

        retry_get_mining_pools=0
        while ([ -z "$response" ] || ! jq -e . >/dev/null 2>&1 <<<"$response" || echo $response | jq 'has("data")' | grep -q 'false') && [ "$retry_get_mining_pools" -lt 2 ]; do
            echo "Cannot get list mining pools. Retrying..."
            sleep 1
            response=$(curl -s --request GET -H "Content-Type:application/json" "$lb_host/mining-pools")
            retry_get_mining_pools=$((retry_get_mining_pools + 1))
        done

        if [ -z "$response" ] || ! jq -e . >/dev/null 2>&1 <<<"$response" || echo $response | jq 'has("data")' | grep -q 'false'; then
            echo "Cannot get list mining pools. Please try again later."
            echo "[]"
        else
            echo "INFO: Finding best mining pool..."
            mining_pools="[]"
            unavailable_mining_pools="[]"
            while read pool; do
                host=$(echo $pool | jq -r '.host')
                port=$(echo $pool | jq -r '.port')
                avg=$(ping -c 2 -W 1 $host | tail -1 | awk '{print $4}' | cut -d '/' -f 2)
                retry=0
                while [ -z "$avg" ] && [ "$retry" -lt 2 ]; do
                    avg=$(ping -c 2 -W 1 $host | tail -1 | awk '{print $4}' | cut -d '/' -f 2)
                    retry=$((retry + 1))
                done

                if [ -z "$avg" ]; then
                    unavailable_mining_pools=$(echo $unavailable_mining_pools | jq --arg host "$host" --arg port "$port" '. += [{"host": $host, "port": $port}]')
                else
                    mining_pools=$(echo $mining_pools | jq --arg avg "$avg" --arg host "$host" --arg port "$port" '. += [{"time": $avg, "host": $host, "port": $port}]')
                fi
            done < <(echo $response | jq '.data' | jq -c '.[]')

            mining_pools=$(echo $mining_pools | jq '[.[] | .time |= tonumber] | sort_by(.time)')
            mining_pools=$(echo $mining_pools | jq -s add <<<"$mining_pools $unavailable_mining_pools" | jq 'map(.host + ":" + .port)')
            echo $mining_pools
        fi
    fi
}

function configure_gpu_nvidia() {
    read -p "Enter the maximum wattage the GPU will use (Default will be 100): " max_wattage
    if [ -z "$max_wattage" ]; then
        max_wattage=100
    fi

    if command -v nvidia-smi &>/dev/null; then
        set -x
        sudo nvidia-smi -pm 1
        sudo nvidia-smi -pl $max_wattage
        { set +x; } 2>/dev/null
    else
        echo "INFO: Tool for configurating GPU is not found. Try to install nvidia-smi"
    fi
}

function download_miner() {
    echo "INFO: download miner soft ......"
    rm -rf "$homepath"/abelminer*
    mkdir -p "$homepath"
    cd $homepath
    wget -q -O "$homepath/$abelminer_archive_name" $download_abelminer_archive_site
    echo "INFO: unzip ......"
    tar xzf "$homepath/$abelminer_archive_name" -C "$homepath" || {
        echo "Error extracting files."
        exit 1
    }
    cp $homepath/$abelminer_folder_name/HELP_MINING_COMMAND_FAIL.txt  $HOME/HELP_MINING_COMMAND_FAIL.txt    
}

# Function to check if the service is installed
function is_service_installed() {
    abelminer_pid=$(ps aux | grep abelminer | grep -v grep | awk '{print $2}')

    if systemctl is-active --quiet gpu-monitor.timer && systemctl is-active --quiet abelmining-restarter.timer && [[ -n $abelminer_pid ]]; then
        return 0 # Return true
    else
        return 1 # Return false
    fi
}

function is_all_service_stopped() {
    abelminer_pid=$(ps aux | grep abelminer | grep -v grep | awk '{print $2}')

    if systemctl is-active --quiet gpu-monitor.timer || systemctl is-active --quiet abelmining-restarter.timer || [[ -n $abelminer_pid ]]; then
        return 1 # Return false
    else
        return 0 # Return true
    fi
}

function get_service_status() {
    echo ""
    if is_service_installed; then
        echo "INFO: Mining Service is Active"
    else
        echo "INFO: Mining Service is Not Active"
    fi
}

function install_daemon_service() {
    echo ""
    echo "INFO: Start GPU Monitoring Service..."
    echo "INFO: The stat collection script operates as a service and requires the sudo privileges."
    echo ""

    # Download the script and make it executable
    if [ ! -d "$collect_stat_script_root_path" ]; then
        sudo mkdir -p "$collect_stat_script_root_path"
        sudo chmod 777 $collect_stat_script_root_path
    fi
    sudo curl -sSL "$mining_script_download_url" -o $collect_stat_script_path
    sudo chmod +x $collect_stat_script_path

    echo "INFO: Done downloading the script for background service. The script is located at $collect_stat_script_path."

    if ! systemctl is-active --quiet gpu-monitor.timer; then
        create_gpu_monitor_service
    fi

    if ! systemctl is-active --quiet abelmining-restarter.timer; then
        create_mining_service
    fi
}

function create_mining_service() {
    sudo bash -c 'cat <<EOF >'"$mining_service_path"'
[Unit]
Description=Abel-Mining-Service

[Service]
ExecStart='"$collect_stat_script_path"' restart '"$account"' 0
Restart=always
Restart=on-failure
RestartSec=1min
User='"$cuser"'
Type=forking

[Install]
WantedBy=multi-user.target
EOF'

    sudo systemctl enable abelmining-restarter.service

    sudo bash -c 'cat <<EOF >'"$mining_timer_path"'
[Unit]
Description=Runs-Abel-Mining-Service-on-boot

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=abelmining-restarter.service

[Install]
WantedBy=timers.target
EOF'

    sudo systemctl daemon-reload
    sudo systemctl enable abelmining-restarter.timer
    sudo systemctl start abelmining-restarter.timer
}

function create_gpu_monitor_service() {
    sudo bash -c 'cat <<EOF >'"$gpu_service_path"'
[Unit]
Description=GPU-Monitoring-Service

[Service]
ExecStart='"$collect_stat_script_path"' start_monitoring
Restart=always
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF'

    sudo systemctl enable gpu-monitor.service

    sudo bash -c 'cat <<EOF >'"$gpu_timer_path"'
[Unit]
Description=Runs-GPU-Monitoring-Service-every-5-minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=gpu-monitor.service

[Install]
WantedBy=timers.target
EOF'

    sudo systemctl daemon-reload
    sudo systemctl enable gpu-monitor.timer
    sudo systemctl start gpu-monitor.timer
}

function query_and_send_miner_stat_detail() {
    # Get miner stat detail
    miner_get_stat_detail_result=$(echo "{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"miner_getstatdetail\"}" | netcat $localhost $api_binding_port -W 1)
    if [ -z "$miner_get_stat_detail_result" ]; then
        miner_get_stat_detail_result="null"
    fi

    # Get the public IP address
    ext_addr=$(curl -s -4 ifconfig.me)
    if [ $? -eq 0 ]; then
        # Get the private IP address
        int_addr=$(ifconfig | grep ether | awk "NR==1 {print \$2}")

        # Get current timestamp
        timestamp=$(date +%s)

        operating_system='Linux'
        if check_hive_os; then
            operating_system='HiveOs'
        fi

        # Construct the JSON string
        result="{\"miner_get_stat_detail\": $miner_get_stat_detail_result, \"ext_addr\": \"$ext_addr\", \"int_addr\": \"$int_addr\", \"timestamp\": \"$timestamp\", \"operating_system\": \"$operating_system\", \"token_name\": \"Abelian\", \"token_symbol\":\"ABEL\"}"
        formatted_timestamp=$(date +%F_%T)
        echo "Sending GPU stats to the server...: $formatted_timestamp - $result"
        # Set timeout for curl to 20 seconds
        response=$(curl -X POST -H "Content-Type: application/json" -d "$result" --max-time 20 $gpustat_receive_endpoint)
        echo "Response: $response"
    fi
}

function stop_restart_mining() {
    # Stop the service if it's running
    if systemctl is-active --quiet abelmining-restarter; then
        sudo systemctl stop abelmining-restarter
    fi

    # Disable and remove the service if it's installed
    if [ -f $mining_service_path ] && systemctl is-enabled --quiet abelmining-restarter; then
        sudo systemctl disable abelmining-restarter
        sudo rm $mining_service_path
    fi

    # Stop the timer if it's running
    if systemctl is-active --quiet abelmining-restarter.timer; then
        sudo systemctl stop abelmining-restarter.timer
    fi

    # Disable and remove the timer if it's installed
    if [ -f $mining_timer_path ] && systemctl is-enabled --quiet abelmining-restarter.timer; then
        sudo systemctl disable abelmining-restarter.timer
        sudo rm $mining_timer_path
    fi
}

function stop_monitoring_gpu() {
    # Stop the service if it's running
    if systemctl is-active --quiet gpu-monitor; then
        sudo systemctl stop gpu-monitor
    fi

    # Disable and remove the service if it's installed
    if [ -f $gpu_service_path ] && systemctl is-enabled --quiet gpu-monitor; then
        sudo systemctl disable gpu-monitor
        sudo rm $gpu_service_path
    fi

    # Stop the timer if it's running
    if systemctl is-active --quiet gpu-monitor.timer; then
        sudo systemctl stop gpu-monitor.timer
    fi

    # Disable and remove the timer if it's installed
    if [ -f $gpu_timer_path ] && systemctl is-enabled --quiet gpu-monitor.timer; then
        sudo systemctl disable gpu-monitor.timer
        sudo rm $gpu_timer_path
    fi
}

function start_mining() {
    if is_service_installed; then
        echo ""
        echo "INFO: Mining Service Already Active."
        return
    fi

    echo "INFO: Starting mining..."

    if command -v lspci &>/dev/null; then
        echo "INFO: check lspci [ OK ]"
    else
        echo "INFO: check lspci [ NoPass ]"
        apt install pciutils -y >/dev/null
        echo "INFO: check lspci [ Fixed ]"
    fi

    lines=()
    # Loop through mining pools
    if [ $(echo "$list_ordered_mining_pools" | jq 'length') -gt 0 ]; then
        while read -r line; do
            lines+=("$line")
        done < <(echo "$list_ordered_mining_pools" | jq -r '.[]')
    fi

    # Construct and execute the mining command
    run_command="./abelminer"
    for item in "${lines[@]}"; do
        if lspci | grep -w VGA | grep -E 'AMD|Radeon'; then
            run_command+=" -P stratums://$account@$item"
        else
            run_command+=" -U -P stratums://$account@$item"
        fi
    done

    run_command+=" --api-bind $localhost:$api_binding_port"

    echo ""
    set -x
    echo "$run_command"

    $run_command &>>out.txt &
    pid=$!
    # Watting the process running
    # sleep 2

    if ! ps -p $pid >/dev/null && grep -q -- "--api-bind" out.txt; then
        echo "INFO: API bind collection has failed. Launching the mining without GPU stats...."
        # Remove --api-bind from run_command
        run_command=$(echo "$run_command" | sed "s/--api-bind $localhost:$api_binding_port//")
        # Execute the modified run_command again
        $run_command &>>out.txt &
        pid=$!
    fi

    # Watting the process running
    sleep 2
    # Check the process is running
    if ! ps -p $pid >/dev/null; then
        echo "Error: There was a problem running the abelminer command."
        exit 1
    else
        { set +x; } 2>/dev/null

        echo ""
        echo "Background mining job PID: $pid"

        case $should_install_gpu_collect_service in
        0) ;;
        *) 
             # Run query_and_send_miner_stat_detail
            install_daemon_service
            ;;
        esac

        # Configure logrotate if available
        echo "$logrotate_content" >"logrotate_abelmining.conf"
        if [ -e "$logrotate_abelmining_config" ]; then
            logrotate -v "$logrotate_abelmining_config" --state "$logrotate_abelmining_state" --force >/dev/null 2>&1 &
            CRONJOB="05 20 * * * /usr/sbin/logrotate $logrotate_abelmining_config --state $logrotate_abelmining_state"
            (
                crontab -l
                echo "$CRONJOB"
            ) | sort - | uniq - | crontab - >/dev/null 2>&1 &

        else
            echo "INFO: Mining started, logrotate installed, but config path not found. Please manually copy abelmine file to your logrotate path (under logrotate.d)"
        fi

        echo ""
        echo "INFO: Mining started."
        echo ""
    fi
}

function stop_mining() {
    if is_all_service_stopped; then
        echo "INFO: Mining Service already stopped."
        return
    fi

    # Kill process send stat miner detail
    echo ""
    echo "INFO: Removing existing Service..."
    stop_monitoring_gpu
    stop_restart_mining
    echo "INFO: Existing Service removed"

    echo "INFO: Stop mining..."
    for i in $(seq 1 5); do

        ps aux | grep abelminer | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1
        ps aux | grep heartbeat | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1
        sleep 1
    done
    echo "INFO: Mining stopped."
}

function menu() {
    while true; do
        echo "=== Manual Options ==="
        echo ""
        echo "1. Start Mining"
        echo "2. Nvidia GPU Monitoring"
        echo "3. Nvidia GPU Change Power Cap"
        echo "4. AMD GPU Monitoring"
        echo "5. Latest Logs"
        echo "6. Stop Mining"
        echo "7. Mining Status"
        echo "8. Exit"
        echo -n "Enter your choice: "
        read manual_option

        case $manual_option in
        1)
            echo ""
            echo "=== Start mining ==="
            echo ""
            start_mining
            echo ""
            ;;
        2)
            echo ""
            echo "=== Nvidia GPU Monitoring ==="
            echo ""
            hardward_info=$(lspci -nn | grep "\[03")
            if lspci -nn | grep "\[03" | grep -iq "nvidia"; then
                nvidia-smi

            else
                echo ""
                echo "INFO: No NVIDIA GPU cards detected."
            fi

            echo ""
            echo "End of GPU status"
            echo "Press Enter to continue."
            echo ""
            read
            ;;
        3)
            echo ""
            echo "=== Configure GPU ==="
            echo ""
            configure_gpu_nvidia
            echo ""
            echo "End of GPU configuration"
            echo "Press Enter to continue."
            echo ""
            read
            ;;
        4)
            echo ""
            echo "=== AMD GPU Monitoring ==="
            echo ""
            hardward_info=$(lspci -nn | grep "\[03")
            if lspci -nn | grep "\[03" | grep -iq "amd"; then
                if check_hive_os; then
                    amd-info
                else
                    lspci | grep -w VGA | grep -E 'AMD|Radeon'
                fi
            else
                echo ""
                echo "INFO: No AMD GPU cards detected."
            fi

            echo ""
            echo "End of GPU status"
            echo "Press Enter to continue."
            echo ""
            read
            ;;
        5)
            echo ""
            echo "=== Latest Logs ==="
            echo ""

            tail -n 30 out.txt

            echo ""
            echo "End of mining status"
            echo "Press Enter to continue."
            echo ""
            read
            ;;
        6)
            echo ""
            echo "=== Trying to stop mining: ==="
            echo ""

            stop_mining

            echo ""
            echo "Press Enter to continue."
            echo ""
            read
            ;;
        7)
            get_service_status
            ;;
        8)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid choice. Please enter a number between 1 and 7."
            ;;
        esac
    done
}

function calculate_md5() {
    local arr=("$@")
    local str=$(printf "%s" "${arr[@]}")
    echo -n "$str" | md5sum | awk '{print $1}'
}

function get_list_mining_pools() {
    lb_host="$hostname_mining_pool_service:$port_mining_pool_service"
    response=""

    if [ -z "$lb_host" ]; then
        load_balancer_message="Load balancer config file not found."
        response="[]"
    else
        response=$(curl -s --request GET -H "Content-Type:application/json" "$lb_host/mining-pools")

        retry_get_mining_pools=0
        while ([ -z "$response" ] || ! jq -e . >/dev/null 2>&1 <<<"$response" || echo "$response" | jq 'has("data")' | grep -q 'false') && [ "$retry_get_mining_pools" -lt 2 ]; do
            retry_message="Cannot get list mining pools. Retrying..."
            sleep 1
            response=$(curl -s --request GET -H "Content-Type:application/json" "$lb_host/mining-pools")
            retry_get_mining_pools=$((retry_get_mining_pools + 1))
        done

        if [ -z "$response" ] || ! jq -e . >/dev/null 2>&1 <<<"$response" || echo "$response" | jq 'has("data")' | grep -q 'false'; then
            error_message="Cannot get list mining pools. Please try again later."
            response="[]"
        fi
    fi

    echo "$response"
}

function check_dependencies() {
    # Check jq package
    if command -v jq &>/dev/null; then
        echo "INFO: check jq [ OK ]"

    else
        echo "INFO: check jq [ NoPass ]"
        echo "INFO: installing jq package..."
        sudo apt-get install -y jq
        echo "INFO: check jq [ Fixed ]"
    fi
    # Check logrotate package
    if command -v logrotate &>/dev/null; then
        echo "INFO: check logrotate  [ OK ]"

    else
        echo "INFO: check logrotate  [ NoPass ]"
        echo "INFO: installing logrotate  package..."
        sudo apt-get install -y logrotate
        echo "INFO: check logrotate  [ Fixed ]"
    fi
}

function main() {
    if [ -n "$3" ]; then
        should_install_gpu_collect_service=$3
    fi

    case $action in
    start_monitoring) ;;
    *)
        check_global_dependencies
        ;;
    esac

    case $action in
    start)
        check_params
        echo ""
        echo "=== Start mining ==="
        start_mining
        ;;
    restart)
        sleep 60
        check_params
        echo ""
        echo "=== Start mining ==="
        start_mining
        ;;
    stop)
        echo ""
        echo "=== Trying to stop mining: ==="
        echo ""
        stop_mining
        ;;
    manual)
        check_params
        menu
        ;;
    start_monitoring)
        query_and_send_miner_stat_detail
        ;;
    status)
        get_service_status
        ;;
    help)
        usage
        ;;
    --help)
        usage
        ;;
    -h)
        usage
        ;;
    *)
        echo
        echo "Error: No such command: ${action}"
        echo
        usage
        ;;
    esac
}

function check_params() {
    ### Check params
    if [ ! -n "$account" ]; then
        echo
        echo "Error: start need Params -> accountxx:passxx"
        echo
        exit 1
    fi
}

function check_global_dependencies() {
    checkMaxPoolAlive
    ### Check dependencies
    check_dependencies

    ### glic block
    if strings -v >/dev/null 2>&1; then
        glibc_version=$(strings /lib/x86_64-linux-gnu/libc.so.6 | grep GLIBC_2.3[2-5] >/dev/null && echo 'true' || echo 'false')
        if [ $glibc_version = 'true' ]; then
            echo "INFO: check glibc >= GLIBC_2.32    [ OK ]"
        else
            echo "INFO: check glibc < GLIBC_2.32    [ Nopass ]"
            upgrade_glibc
        fi
    else
        echo "Warning: strings command not found, skip glibc check ."
    fi

    ### miner block
    if ! checkfilebinary "$abelminer_folder_name/abelminer"; then
        echo "INFO: check localfile -> abelminer  [ Nopass ]"
        download_miner
        echo "INFO: abelminer $abelminer_folder_name has been downloaded"
    else
        echo "INFO: check localfile -> abelminer  [ OK ]"
        echo "INFO: abelminer $abelminer_folder_name is already installed"
    fi

    if [ -n "$account" ]; then
        echo "$formatted_datetime $account" >> $credential_file
    fi

    cd "$homepath"/$abelminer_folder_name/ || {
        echo "Failed to change directory."
        exit 1
    }

    ### Ordered mining pools
    if [ "$is_maxpool_alive" -eq 1 ]; then 
        result=$(get_ordered_mining_pools)
        list_ordered_mining_pools=$(echo "$result" | tail -n 1)
        if [ -z "$list_ordered_mining_pools" ] || [ "$list_ordered_mining_pools" == "[]" ]; then
            if [ -s "ordered_mining_pools.txt" ]; then
                list_ordered_mining_pools=$(cat "ordered_mining_pools.txt")
            fi
        else
            echo "$list_ordered_mining_pools" >"ordered_mining_pools.txt"
        fi
    else
        if [ -s "ordered_mining_pools.txt" ]; then
            list_ordered_mining_pools=$(cat "ordered_mining_pools.txt")
        fi
    fi

    if [ -z "$list_ordered_mining_pools" ] || [ "$list_ordered_mining_pools" == "[]" ]; then
        echo "INFO: Unable to retrieve the list of mining pools."
        echo "INFO: Using the default list of mining pools."
        list_ordered_mining_pools="$list_mining_pool_default"
    fi
    echo "INFO: List mining pool: $list_ordered_mining_pools"
}
main "$@"
