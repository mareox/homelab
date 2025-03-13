#!/bin/bash
# VAULTWARDEN-SYNC
# A tool to synchronize Vaultwarden data between systems

# Script Information
SCRIPT_VERSION="1.0.0"
SCRIPT_BRANCH="master"

# Terminal Colors
BLUE='\e[34m'
GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
PURPLE='\e[35m'
NC='\e[0m' # No Color

# Default Variables
LOCAL_VW_DATA="/vw-data"
REMOTE_HOST=""
REMOTE_PORT="22"
REMOTE_USER=""
REMOTE_VW_DATA="/vw-data"
SSH_KEY=""
DOCKER_CMD="docker"
PODMAN_CMD="podman"
CONTAINER_NAME="vaultwarden"
BACKUP_DIR=""
SQLITE_BACKUP_DIR="/mx-server/backups/BK_vaultwarden"
SQLITE_MAX_BACKUPS=30
LOG_PATH="/var/log/vaultwarden-sync.log"
CONFIG_FILE="/etc/vaultwarden-sync.conf"
DEBUG_LOGS=false
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Help and Version Information
function show_help {
    echo -e "${BLUE}Vaultwarden-Sync ${SCRIPT_VERSION}${NC}"
    echo "Usage: ./vaultwarden-sync [options] command"
    echo ""
    echo "Commands:"
    echo "  pull                Pull Vaultwarden data from remote host"
    echo "  push                Push Vaultwarden data to remote host"
    echo "  auto                Determine which host has newest data and sync accordingly"
    echo "  version             Display version information"
    echo "  config              Create or edit configuration file"
    echo "  logs                Display logs"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  -d, --debug         Enable debug logging"
    echo "  -c, --config FILE   Use specified config file instead of default"
    echo "  -r, --remote HOST   Specify remote host"
    echo "  -u, --user USER     Specify remote user"
    echo "  -p, --port PORT     Specify SSH port (default: 22)"
    echo "  -k, --key FILE      Specify SSH key file"
    echo "  -b, --backup DIR    Create backup in specified directory before sync"
    echo ""
    exit 0
}

function show_version {
    echo -e "${BLUE}Vaultwarden-Sync ${SCRIPT_VERSION} - ${SCRIPT_BRANCH} branch${NC}"
    echo "A tool to synchronize Vaultwarden data between systems"
    exit 0
}

# Logging Functions
function log_write {
    local LOG_ENTRY="$(date +"%b %d %H:%M:%S") $(hostname) vaultwarden-sync[$$]: $1"
    echo -e "${LOG_ENTRY}" >> "${LOG_PATH}"
    
    if [[ "${DEBUG_LOGS}" == true && "$2" == "debug" ]]; then
        echo -e "${PURPLE}DEBUG: $1${NC}"
    elif [[ "$2" == "error" ]]; then
        echo -e "${RED}ERROR: $1${NC}" >&2
    elif [[ "$2" == "warning" ]]; then
        echo -e "${YELLOW}WARNING: $1${NC}"
    elif [[ "$2" == "info" ]]; then
        echo -e "${GREEN}INFO: $1${NC}"
    elif [[ "$2" == "notice" ]]; then
        echo -e "${BLUE}NOTICE: $1${NC}"
    fi
}

function debug_log {
    if [[ "${DEBUG_LOGS}" == true ]]; then
        log_write "$1" "debug"
    fi
}

function error_log {
    log_write "$1" "error"
}

function warning_log {
    log_write "$1" "warning"
}

function info_log {
    log_write "$1" "info"
}

function notice_log {
    log_write "$1" "notice"
}

# Configuration Functions
function load_config {
    if [[ -f "${CONFIG_FILE}" ]]; then
        debug_log "Loading config from ${CONFIG_FILE}"
        source "${CONFIG_FILE}"
        return 0
    else
        warning_log "Config file ${CONFIG_FILE} not found"
        return 1
    fi
}

function create_config {
    if [[ -f "${CONFIG_FILE}" ]]; then
        warning_log "Config file already exists at ${CONFIG_FILE}"
        read -p "Do you want to overwrite it? (y/n): " OVERWRITE
        if [[ "${OVERWRITE}" != "y" ]]; then
            notice_log "Config creation cancelled"
            return 1
        fi
    fi
    
    notice_log "Creating new config file at ${CONFIG_FILE}"
    
    # Get user input for configuration
    read -p "Remote Host: " input_remote_host
    read -p "Remote User (default: root): " input_remote_user
    input_remote_user=${input_remote_user:-root}
    read -p "Remote SSH Port (default: 22): " input_remote_port
    input_remote_port=${input_remote_port:-22}
    read -p "SSH Key File (default: ~/.ssh/id_rsa): " input_ssh_key
    input_ssh_key=${input_ssh_key:-~/.ssh/id_rsa}
    read -p "Local Vaultwarden Data Path (default: /vw-data): " input_local_path
    input_local_path=${input_local_path:-/vw-data}
    read -p "Remote Vaultwarden Data Path (default: /vw-data): " input_remote_path
    input_remote_path=${input_remote_path:-/vw-data}
    read -p "Container Engine (docker/podman, default: docker): " input_container_engine
    input_container_engine=${input_container_engine:-docker}
    read -p "Container Name (default: vaultwarden): " input_container_name
    input_container_name=${input_container_name:-vaultwarden}
    read -p "SQLite Backup Directory (default: /mx-server/backups/BK_vaultwarden): " input_sqlite_backup_dir
    input_sqlite_backup_dir=${input_sqlite_backup_dir:-/mx-server/backups/BK_vaultwarden}
    read -p "Max SQLite Backups to keep (default: 30): " input_sqlite_max_backups
    input_sqlite_max_backups=${input_sqlite_max_backups:-30}
    
    # Create config file
    cat > "${CONFIG_FILE}" << EOL
# Vaultwarden-Sync Configuration File
# Created: $(date)
# Version: ${SCRIPT_VERSION}

# Remote Host Settings
REMOTE_HOST="${input_remote_host}"
REMOTE_USER="${input_remote_user}"
REMOTE_PORT="${input_remote_port}"
SSH_KEY="${input_ssh_key}"

# Vaultwarden Settings
LOCAL_VW_DATA="${input_local_path}"
REMOTE_VW_DATA="${input_remote_path}"
CONTAINER_NAME="${input_container_name}"

# Container Engine Settings
CONTAINER_ENGINE="${input_container_engine}"

# Backup Settings
BACKUP_DIR="/var/backups/vaultwarden-sync"
SQLITE_BACKUP_DIR="${input_sqlite_backup_dir}"
SQLITE_MAX_BACKUPS=${input_sqlite_max_backups}

# Debug Settings
DEBUG_LOGS=false
EOL

    # Set permissions
    chmod 600 "${CONFIG_FILE}"
    
    info_log "Config file created successfully at ${CONFIG_FILE}"
    return 0
}

# Container Management Functions
function stop_container {
    local host="$1"
    local container="$2"
    local engine="$3"
    
    debug_log "Stopping container ${container} on ${host} using ${engine}"
    
    if [[ "${host}" == "local" ]]; then
        if [[ "${engine}" == "podman" ]]; then
            ${PODMAN_CMD} stop "${container}"
        else
            ${DOCKER_CMD} stop "${container}"
        fi
    else
        if [[ "${engine}" == "podman" ]]; then
            ssh -i "${SSH_KEY}" -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" "${PODMAN_CMD} stop ${container}"
        else
            ssh -i "${SSH_KEY}" -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" "${DOCKER_CMD} stop ${container}"
        fi
    fi
    
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error_log "Failed to stop container ${container} on ${host} (Exit code: ${exit_code})"
        return 1
    fi
    
    info_log "Container ${container} stopped successfully on ${host}"
    return 0
}

function start_container {
    local host="$1"
    local container="$2"
    local engine="$3"
    
    debug_log "Starting container ${container} on ${host} using ${engine}"
    
    if [[ "${host}" == "local" ]]; then
        if [[ "${engine}" == "podman" ]]; then
            ${PODMAN_CMD} start "${container}"
        else
            ${DOCKER_CMD} start "${container}"
        fi
    else
        if [[ "${engine}" == "podman" ]]; then
            ssh -i "${SSH_KEY}" -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" "${PODMAN_CMD} start ${container}"
        else
            ssh -i "${SSH_KEY}" -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" "${DOCKER_CMD} start ${container}"
        fi
    fi
    
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error_log "Failed to start container ${container} on ${host} (Exit code: ${exit_code})"
        return 1
    fi
    
    info_log "Container ${container} started successfully on ${host}"
    return 0
}

# Backup Functions
function create_backup {
    local source_path="$1"
    local backup_name="$2"
    
    if [[ -z "${BACKUP_DIR}" ]]; then
        warning_log "Backup directory not set, skipping backup"
        return 0
    fi
    
    # Create backup directory if it doesn't exist
    mkdir -p "${BACKUP_DIR}"
    
    debug_log "Creating backup of ${source_path} to ${BACKUP_DIR}/${backup_name}.tar.gz"
    
    tar -czf "${BACKUP_DIR}/${backup_name}.tar.gz" -C $(dirname "${source_path}") $(basename "${source_path}")
    
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error_log "Failed to create backup (Exit code: ${exit_code})"
        return 1
    fi
    
    info_log "Backup created successfully at ${BACKUP_DIR}/${backup_name}.tar.gz"
    return 0
}

# SQLite Database Backup Function
function backup_sqlite_db {
    # Database backup settings
    local BACKUP_NAME="db-$(date '+%Y%m%d-%H%M').sqlite3"
    local DB_FILE="${LOCAL_VW_DATA}/db.sqlite3"
    
    debug_log "Creating SQLite database backup at ${SQLITE_BACKUP_DIR}/${BACKUP_NAME}"
    
    # Create the backup directory if it doesn't exist
    mkdir -p "${SQLITE_BACKUP_DIR}"
    
    # Run the backup command
    sqlite3 "${DB_FILE}" ".backup '${SQLITE_BACKUP_DIR}/${BACKUP_NAME}'"
    
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error_log "Failed to create SQLite database backup (Exit code: ${exit_code})"
        return 1
    fi
    
    # Delete old backups if there are more than the maximum allowed
    cd "${SQLITE_BACKUP_DIR}"
    local BACKUPS_COUNT=$(ls -1 | grep "^db-[0-9]\{8\}-[0-9]\{4\}.sqlite3$" | wc -l)
    if [ $BACKUPS_COUNT -gt $SQLITE_MAX_BACKUPS ]; then
        ls -1t | grep "^db-[0-9]\{8\}-[0-9]\{4\}.sqlite3$" | tail -$((BACKUPS_COUNT - SQLITE_MAX_BACKUPS)) | xargs -d '\n' rm
        info_log "Cleaned up old SQLite database backups, keeping ${SQLITE_MAX_BACKUPS} most recent"
    fi
    
    info_log "SQLite database backup created successfully at ${SQLITE_BACKUP_DIR}/${BACKUP_NAME}"
    return 0
}

# Sync Functions
function pull_data {
    # Backup local data first
    create_backup "${LOCAL_VW_DATA}" "vaultwarden_local_${TIMESTAMP}"
    
    # Backup SQLite database
    backup_sqlite_db
    
    # Stop local container
    stop_container "local" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
    
    # Stop remote container
    stop_container "remote" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
    
    # Rsync data from remote to local
    info_log "Pulling data from ${REMOTE_HOST}:${REMOTE_VW_DATA} to ${LOCAL_VW_DATA}"
    
    rsync -avz --delete -e "ssh -i ${SSH_KEY} -p ${REMOTE_PORT}" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_VW_DATA}/" "${LOCAL_VW_DATA}/"
    
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error_log "Failed to sync data from remote (Exit code: ${exit_code})"
        # Try to start containers again before exiting
        start_container "local" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
        start_container "remote" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
        return 1
    fi
    
    # Start containers again
    start_container "local" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
    start_container "remote" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
    
    info_log "Pull completed successfully"
    return 0
}

function push_data {
    # Backup remote data first
    ssh -i "${SSH_KEY}" -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" \
        "mkdir -p /var/backups/vaultwarden-sync && tar -czf /var/backups/vaultwarden-sync/vaultwarden_remote_${TIMESTAMP}.tar.gz -C $(dirname ${REMOTE_VW_DATA}) $(basename ${REMOTE_VW_DATA})"
    
    # Backup SQLite database
    backup_sqlite_db
    
    # Stop local container
    stop_container "local" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
    
    # Stop remote container
    stop_container "remote" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
    
    # Rsync data from local to remote
    info_log "Pushing data from ${LOCAL_VW_DATA} to ${REMOTE_HOST}:${REMOTE_VW_DATA}"
    
    rsync -avz --delete -e "ssh -i ${SSH_KEY} -p ${REMOTE_PORT}" \
        "${LOCAL_VW_DATA}/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_VW_DATA}/"
    
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error_log "Failed to sync data to remote (Exit code: ${exit_code})"
        # Try to start containers again before exiting
        start_container "local" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
        start_container "remote" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
        return 1
    fi
    
    # Start containers again
    start_container "local" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
    start_container "remote" "${CONTAINER_NAME}" "${CONTAINER_ENGINE}"
    
    info_log "Push completed successfully"
    return 0
}

function auto_sync {
    # Get last modified time of local directory
    local local_time=$(find "${LOCAL_VW_DATA}" -type f -printf '%T@\n' | sort -n | tail -1)
    
    # Get last modified time of remote directory
    local remote_time=$(ssh -i "${SSH_KEY}" -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" \
        "find ${REMOTE_VW_DATA} -type f -printf '%T@\n' | sort -n | tail -1")
    
    # Compare timestamps
    if [[ $(echo "${local_time} > ${remote_time}" | bc) -eq 1 ]]; then
        info_log "Local data is newer, pushing to remote"
        push_data
    else
        info_log "Remote data is newer, pulling to local"
        pull_data
    fi
}

# Display logs
function show_logs {
    if [[ -f "${LOG_PATH}" ]]; then
        cat "${LOG_PATH}"
    else
        error_log "Log file ${LOG_PATH} not found"
        return 1
    fi
}

# Parse command line arguments
COMMAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -v|--version)
            show_version
            ;;
        -d|--debug)
            DEBUG_LOGS=true
            shift
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -r|--remote)
            REMOTE_HOST="$2"
            shift 2
            ;;
        -u|--user)
            REMOTE_USER="$2"
            shift 2
            ;;
        -p|--port)
            REMOTE_PORT="$2"
            shift 2
            ;;
        -k|--key)
            SSH_KEY="$2"
            shift 2
            ;;
        -b|--backup)
            BACKUP_DIR="$2"
            shift 2
            ;;
        pull|push|auto|version|config|logs)
            COMMAND="$1"
            shift
            ;;
        *)
            error_log "Unknown option: $1"
            show_help
            ;;
    esac
done

# Load configuration file
load_config

# Check if a command was provided
if [[ -z "${COMMAND}" ]]; then
    error_log "No command specified"
    show_help
fi

# Check for required variables
if [[ "${COMMAND}" != "version" && "${COMMAND}" != "config" && "${COMMAND}" != "logs" ]]; then
    if [[ -z "${REMOTE_HOST}" ]]; then
        error_log "Remote host not specified"
        exit 1
    fi
    
    if [[ -z "${REMOTE_USER}" ]]; then
        REMOTE_USER="root"
        warning_log "Remote user not specified, using default: ${REMOTE_USER}"
    fi
    
    if [[ -z "${SSH_KEY}" ]]; then
        SSH_KEY="~/.ssh/id_rsa"
        warning_log "SSH key not specified, using default: ${SSH_KEY}"
    fi
    
    # Determine container engine
    if [[ -z "${CONTAINER_ENGINE}" ]]; then
        if command -v docker &> /dev/null; then
            CONTAINER_ENGINE="docker"
        elif command -v podman &> /dev/null; then
            CONTAINER_ENGINE="podman"
        else
            error_log "No container engine found (docker or podman)"
            exit 1
        fi
    fi
fi

# Execute the requested command
case "${COMMAND}" in
    pull)
        pull_data
        ;;
    push)
        push_data
        ;;
    auto)
        auto_sync
        ;;
    version)
        show_version
        ;;
    config)
        create_config
        ;;
    logs)
        show_logs
        ;;
    *)
        error_log "Unknown command: ${COMMAND}"
        show_help
        ;;
esac

exit $?
