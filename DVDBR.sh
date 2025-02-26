#!/bin/bash

# Define timestamp for logs and backup filenames
TIMESTAMP=$(date +"%Y%m%d_%H%M_%3N")
LOGFILE="DVDBR_${TIMESTAMP}.log"

# Function to log messages
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S.%3N")] $1" | tee -a "$LOGFILE"
}

# Check if the user is in the docker group or requires sudo
if ! groups | grep -q '\bdocker\b'; then
    log "User is not in the docker group, requesting sudo access."
    sudo -v || { log "Failed to obtain sudo access."; exit 1; }
    SUDO_CMD="sudo"
else
    SUDO_CMD=""
fi

# List available Docker volumes
VOLUMES=$($SUDO_CMD docker volume ls --format "{{.Name}}")
if [[ -z "$VOLUMES" ]]; then
    log "No Docker volumes found. Exiting."
    exit 1
fi

# Ask which volumes to backup
log "Available Docker volumes:"
echo "$VOLUMES"
read -p "Enter the volume(s) to backup (space-separated): " SELECTED_VOLUMES

# Ask if timestamp should be included in the backup file name
read -p "Include timestamp in backup filename? [y/N]: " INCLUDE_TIMESTAMP

# Find running containers using selected volumes
declare -A CONTAINER_MAP
for VOLUME in $SELECTED_VOLUMES; do
    while read -r CONTAINER_ID; do
        if [[ -n "$CONTAINER_ID" ]]; then
            CONTAINER_NAME=$($SUDO_CMD docker ps --filter "id=$CONTAINER_ID" --format "{{.Names}}")
            CONTAINER_MAP["$CONTAINER_ID"]="$CONTAINER_NAME ($CONTAINER_ID)"
        fi
    done < <($SUDO_CMD docker ps --format "{{.ID}}" --filter "volume=$VOLUME")
done

# Display affected containers
if [[ "${#CONTAINER_MAP[@]}" -gt 0 ]]; then
    log "The following containers use the selected volumes and may be impacted: ${CONTAINER_MAP[*]}"
fi

# Ask if containers should be stopped before backup
read -p "Do you want to stop them before backup? (recommended) [y/N]: " STOP_CONTAINERS

# Ask for backup method
read -p "Save locally? [y/N]: " SAVE_LOCAL
read -p "Save to remote server via SSH? [y/N]: " SAVE_REMOTE

# Ask for local backup path if needed
if [[ "$SAVE_LOCAL" =~ ^[Yy]$ ]]; then
    read -p "Enter local backup directory (default: current directory): " LOCAL_PATH
    LOCAL_PATH=${LOCAL_PATH:-$(pwd)}
    mkdir -p "$LOCAL_PATH"
fi

# Ask for SSH details if remote backup is selected
if [[ "$SAVE_REMOTE" =~ ^[Yy]$ ]]; then
    read -p "Enter SSH private key path (default: ~/.ssh/id_rsa): " SSH_KEY
    SSH_KEY=${SSH_KEY:-~/.ssh/id_rsa}
    read -p "Enter SSH user: " SSH_USER
    read -p "Enter SSH server hostname/IP: " SSH_HOST
    read -p "Enter remote backup directory (default: ~/BACKUP): " REMOTE_PATH
    REMOTE_PATH=${REMOTE_PATH:-~/BACKUP}
fi

# Ask if containers should be restarted after backup (only if they were stopped)
if [[ "$STOP_CONTAINERS" =~ ^[Yy]$ ]]; then
    read -p "Restart stopped containers after backup? [y/N]: " RESTART_CONTAINERS
fi

# Summary before execution
echo -e "\nSummary of actions:"
echo "- Selected volumes: $SELECTED_VOLUMES"
echo "- Containers that may be using these volumes: ${CONTAINER_MAP[*]}"
echo "- Stop containers before backup: ${STOP_CONTAINERS}";
echo "- Restart stopped containers after backup: ${RESTART_CONTAINERS}";
echo "- Save locally: ${SAVE_LOCAL}"; [[ "$SAVE_LOCAL" =~ ^[Yy]$ ]] && echo "  -> Path: $LOCAL_PATH"
echo "- Save remotely: ${SAVE_REMOTE}"; [[ "$SAVE_REMOTE" =~ ^[Yy]$ ]] && echo "  -> SSH: $SSH_USER@$SSH_HOST:$REMOTE_PATH"
read -p "Proceed with backup? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Backup cancelled."; exit 0; }

# Stop containers if confirmed
if [[ "$STOP_CONTAINERS" =~ ^[Yy]$ ]]; then
    for CONTAINER_ID in "${!CONTAINER_MAP[@]}"; do
        log "Stopping container: ${CONTAINER_MAP[$CONTAINER_ID]}"
        $SUDO_CMD docker stop "$CONTAINER_ID"
    done
fi

# Perform backup
for VOLUME in $SELECTED_VOLUMES; do
    BACKUP_FILE="$VOLUME.tar.gz"
    [[ "$INCLUDE_TIMESTAMP" =~ ^[Yy]$ ]] && BACKUP_FILE="${VOLUME}_${TIMESTAMP}.tar.gz"

    if [[ "$SAVE_LOCAL" =~ ^[Yy]$ ]]; then
        log "Saving $VOLUME locally to $LOCAL_PATH/$BACKUP_FILE"
        $SUDO_CMD docker run --rm -v $VOLUME:/data:ro -v "$LOCAL_PATH:/backup" alpine tar czf "/backup/$BACKUP_FILE" -C /data .
    fi
    
    if [[ "$SAVE_REMOTE" =~ ^[Yy]$ ]]; then
        log "Streaming $VOLUME backup directly to remote server via ssh cat"
        if ! $SUDO_CMD docker run --rm -v $VOLUME:/data:ro alpine sh -c "tar czf - -C /data ." | ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "cat > $REMOTE_PATH/$BACKUP_FILE"; then
            log "⚠️ ssh cat failed, trying rsync..."
            if ! rsync -avz -e "ssh -i $SSH_KEY" "$LOCAL_PATH/$BACKUP_FILE" "$SSH_USER@$SSH_HOST:$REMOTE_PATH/"; then
                log "⚠️ rsync failed, trying SCP..."
                scp -i "$SSH_KEY" "$LOCAL_PATH/$BACKUP_FILE" "$SSH_USER@$SSH_HOST:$REMOTE_PATH/"
            fi
        fi
    fi

done

# Restart stopped containers if requested
if [[ "$STOP_CONTAINERS" =~ ^[Yy]$ && "$RESTART_CONTAINERS" =~ ^[Yy]$ ]]; then
    for CONTAINER_ID in "${!CONTAINER_MAP[@]}"; do
        log "Restarting container: ${CONTAINER_MAP[$CONTAINER_ID]}"
        $SUDO_CMD docker start "$CONTAINER_ID"
    done
fi

log "Backup process completed successfully."
