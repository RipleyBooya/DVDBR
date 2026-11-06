#!/usr/bin/env bash

# ==============================================================================
# Project: DVDBR (Docker Volume Dump Backup & Restore)
# Version: 2.2.0
# Description: Enterprise-grade Docker volume backup & restore tool with CLI
#              flags, interactive UI, signal trapping, Zstandard (zstd) multi-threaded
#              compression, and optional GPG symmetric encryption.
# ==============================================================================

set -eo pipefail

# --- Global Configurations & Defaults ---
SCRIPT_NAME=$(basename "$0")
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="DVDBR_${TIMESTAMP}.log"

# Internal tracking
STOPPED_CONTAINERS=()
MODE=""
VOLUMES_TO_BACKUP=()
TARGET_VOLUME=""
RESTORE_ARCHIVE=""
SAVE_LOCAL=false
SAVE_REMOTE=false
LOCAL_DIR="./backups"
REMOTE_TARGET=""
SSH_KEY="$HOME/.ssh/id_rsa"
STOP_CONTAINERS=true
USE_TIMESTAMP=true
NON_INTERACTIVE=false
VERBOSE=false
TRANSFER_PROTO="stream" # Options: stream, rsync, scp
STAGE_DIR="/tmp"
ENCRYPT=false
PASSPHRASE=""

# --- Logging & Helpers ---

log() {
    local level="$1"
    shift
    local msg="$*"
    local log_entry="[$(date +"%Y-%m-%d %H:%M:%S")] [$level] $msg"
    echo "$log_entry" | tee -a "$LOGFILE"
}

info()    { log "INFO" "$@"; }
warn()    { log "WARN" "$@"; }
error()   { log "ERROR" "$@" >&2; }
debug()   { [[ "$VERBOSE" == true ]] && log "DEBUG" "$@"; }

die() {
    error "$1"
    exit "${2:-1}"
}

expand_path() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

get_avail_space_human() {
    local dir="$1"
    local parent_dir
    parent_dir=$(dirname "$dir")
    while [[ ! -d "$parent_dir" && "$parent_dir" != "/" ]]; do
        parent_dir=$(dirname "$parent_dir")
    done
    [[ -d "$parent_dir" ]] || parent_dir="/"
    df -h "$parent_dir" 2>/dev/null | awk 'NR==2 {print $4}'
}

# Cleanup Trap: Restores stopped containers on normal or abnormal termination
cleanup() {
    local exit_code=$?
    if [[ ${#STOPPED_CONTAINERS[@]} -gt 0 ]]; then
        warn "Process termination sequence triggered. Restoring stopped container state..."
        for cid in "${STOPPED_CONTAINERS[@]}"; do
            info "Restarting container: $cid"
            $DOCKER_CMD start "$cid" >/dev/null 2>&1 || error "Failed to restart container: $cid"
        done
    fi
    exit "$exit_code"
}
trap cleanup EXIT SIGINT SIGTERM

# Verify Docker engine connectivity & determine root/sudo usage
check_docker_environment() {
    if docker info >/dev/null 2>&1; then
        DOCKER_CMD="docker"
    elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
        DOCKER_CMD="sudo docker"
    else
        die "Docker engine is unreachable. Ensure Docker daemon is running and privileges are correct."
    fi
    debug "Docker command mapped to: $DOCKER_CMD"
}

# --- Core Business Logic ---

stop_associated_containers() {
    local vols=("$@")
    declare -A containers_map

    for vol in "${vols[@]}"; do
        while read -r cid; do
            if [[ -n "$cid" ]]; then
                cname=$($DOCKER_CMD ps --filter "id=$cid" --format "{{.Names}}")
                containers_map["$cid"]="$cname"
            fi
        done < <($DOCKER_CMD ps --quiet --filter "volume=$vol")
    done

    if [[ ${#containers_map[@]} -eq 0 ]]; then
        info "No active containers bound to selected volume(s)."
        return 0
    fi

    warn "Active containers associated with volume(s):"
    for cid in "${!containers_map[@]}"; do
        echo "  - ${containers_map[$cid]} ($cid)"
    done

    if [[ "$NON_INTERACTIVE" == false && "$STOP_CONTAINERS" == true ]]; then
        read -rp "Stop affected containers during operations? [Y/n]: " ans
        [[ "$ans" =~ ^[Nn]$ ]] && STOP_CONTAINERS=false
    fi

    if [[ "$STOP_CONTAINERS" == true ]]; then
        for cid in "${!containers_map[@]}"; do
            info "Stopping container: ${containers_map[$cid]} ($cid)..."
            if $DOCKER_CMD stop "$cid" >/dev/null; then
                STOPPED_CONTAINERS+=("$cid")
            else
                error "Failed to stop container $cid. Aborting operation."
                return 1
            fi
        done
    fi
}

execute_backup() {
    info "Initiating Backup Operations (Compression Engine: zstd)..."
    local local_dest remote_host remote_dir stage_dest

    if [[ "$SAVE_LOCAL" == false && "$SAVE_REMOTE" == false ]]; then
        die "No backup destination defined (Local or Remote must be selected)."
    fi

    if [[ "$ENCRYPT" == true ]]; then
        if ! command -v gpg >/dev/null 2>&1; then
            die "Symmetric encryption requested but 'gpg' utility was not found on host."
        fi
        if [[ -z "$PASSPHRASE" && "$NON_INTERACTIVE" == true ]]; then
            die "Non-interactive encryption requires a passphrase passed via --passphrase or PASSPHRASE env var."
        fi
        if [[ -z "$PASSPHRASE" ]]; then
            read -rsp "Enter passphrase for symmetric GPG encryption: " PASSPHRASE
            echo ""
            read -rsp "Confirm passphrase: " passphrase_confirm
            echo ""
            [[ "$PASSPHRASE" == "$passphrase_confirm" ]] || die "Passphrases do not match."
        fi
    fi

    if [[ "$SAVE_LOCAL" == true ]]; then
        local_dest=$(expand_path "$LOCAL_DIR")
        mkdir -p "$local_dest" || die "Cannot create local backup directory: $local_dest"
        info "Local destination: $local_dest (Available space: $(get_avail_space_human "$local_dest"))"
    fi

    if [[ "$SAVE_REMOTE" == true ]]; then
        [[ -z "$REMOTE_TARGET" ]] && die "Remote SSH target not specified (expected: user@host:/path)."
        SSH_KEY=$(expand_path "$SSH_KEY")
        [[ ! -f "$SSH_KEY" ]] && die "Specified SSH identity file not found: $SSH_KEY"

        if [[ "$REMOTE_TARGET" =~ ^([^:]+):(.+)$ ]]; then
            remote_host="${BASH_REMATCH[1]}"
            remote_dir="${BASH_REMATCH[2]}"
        else
            die "Invalid remote format. Expected user@host:/remote/path"
        fi

        if [[ "$TRANSFER_PROTO" == "rsync" || "$TRANSFER_PROTO" == "scp" ]]; then
            stage_dest=$(expand_path "$STAGE_DIR")
            mkdir -p "$stage_dest" || die "Cannot create staging directory: $stage_dest"
            info "Remote staging dir: $stage_dest (Available space: $(get_avail_space_human "$stage_dest"))"
        fi
    fi

    stop_associated_containers "${VOLUMES_TO_BACKUP[@]}"

    for vol in "${VOLUMES_TO_BACKUP[@]}"; do
        local archive_name="${vol}"
        [[ "$USE_TIMESTAMP" == true ]] && archive_name="${vol}_${TIMESTAMP}"
        archive_name="${archive_name}.tar.zst"
        [[ "$ENCRYPT" == true ]] && archive_name="${archive_name}.gpg"

        info "Processing Volume: $vol"

        # Construct tar command with multi-threaded zstd
        local container_tar_cmd="apk add --no-cache zstd >/dev/null 2>&1 && tar -I 'zstd -T0 -10' -cf - -C /volume_data ."

        # 1. Local Backup
        if [[ "$SAVE_LOCAL" == true ]]; then
            local target_path="$local_dest/$archive_name"
            info "Generating local archive: $target_path"
            if [[ "$ENCRYPT" == true ]]; then
                $DOCKER_CMD run --rm -v "$vol":/volume_data:ro alpine sh -c "$container_tar_cmd" |                     gpg --symmetric --cipher-algo AES256 --batch --yes --passphrase-fd 0 --output "$target_path" <<< "$PASSPHRASE"
            else
                $DOCKER_CMD run --rm -v "$vol":/volume_data:ro alpine sh -c "$container_tar_cmd" > "$target_path"
            fi
            info "Local backup successfully created for $vol."
        fi

        # 2. Remote Backup
        if [[ "$SAVE_REMOTE" == true ]]; then
            info "Transferring $vol using protocol [$TRANSFER_PROTO] to $remote_host..."
            ssh -i "$SSH_KEY" "$remote_host" "mkdir -p '$remote_dir'"

            local active_proto="$TRANSFER_PROTO"

            if [[ "$active_proto" == "stream" ]]; then
                info "Streaming direct zstd pipe to $remote_host:$remote_dir/$archive_name..."
                local stream_success=false

                if [[ "$ENCRYPT" == true ]]; then
                    if $DOCKER_CMD run --rm -v "$vol":/volume_data:ro alpine sh -c "$container_tar_cmd" |                        gpg --symmetric --cipher-algo AES256 --batch --yes --passphrase-fd 0 <<< "$PASSPHRASE" |                        ssh -i "$SSH_KEY" "$remote_host" "cat > '$remote_dir/$archive_name.tmp' && mv '$remote_dir/$archive_name.tmp' '$remote_dir/$archive_name'"; then
                        stream_success=true
                    fi
                else
                    if $DOCKER_CMD run --rm -v "$vol":/volume_data:ro alpine sh -c "$container_tar_cmd" |                        ssh -i "$SSH_KEY" "$remote_host" "cat > '$remote_dir/$archive_name.tmp' && mv '$remote_dir/$archive_name.tmp' '$remote_dir/$archive_name'"; then
                        stream_success=true
                    fi
                fi

                if [[ "$stream_success" == true ]]; then
                    info "Direct SSH stream succeeded for $vol."
                else
                    warn "Direct SSH streaming failed. Falling back to staging transfer..."
                    active_proto="rsync"
                fi
            fi

            if [[ "$active_proto" == "rsync" || "$active_proto" == "scp" ]]; then
                stage_dest=$(expand_path "$STAGE_DIR")
                mkdir -p "$stage_dest"
                local stage_file="$stage_dest/dvdbr_${archive_name}"

                info "Creating temporary stage file at $stage_file (Available space: $(get_avail_space_human "$stage_dest"))..."
                if [[ "$ENCRYPT" == true ]]; then
                    $DOCKER_CMD run --rm -v "$vol":/volume_data:ro alpine sh -c "$container_tar_cmd" |                         gpg --symmetric --cipher-algo AES256 --batch --yes --passphrase-fd 0 --output "$stage_file" <<< "$PASSPHRASE"
                else
                    $DOCKER_CMD run --rm -v "$vol":/volume_data:ro alpine sh -c "$container_tar_cmd" > "$stage_file"
                fi

                if [[ "$active_proto" == "rsync" ]] && command -v rsync >/dev/null 2>&1; then
                    if rsync -avz --partial --inplace -e "ssh -i $SSH_KEY" "$stage_file" "$remote_host:$remote_dir/$archive_name"; then
                        info "Fallback transfer via rsync succeeded."
                    else
                        warn "Rsync failed. Falling back to SCP..."
                        scp -i "$SSH_KEY" "$stage_file" "$remote_host:$remote_dir/$archive_name"
                    fi
                else
                    scp -i "$SSH_KEY" "$stage_file" "$remote_host:$remote_dir/$archive_name"
                fi
                rm -f "$stage_file"
            fi
        fi
    done
    info "Backup procedure completed."
}

execute_restore() {
    info "Initiating Restore Operations..."

    RESTORE_ARCHIVE=$(expand_path "$RESTORE_ARCHIVE")
    [[ ! -f "$RESTORE_ARCHIVE" ]] && die "Backup archive not found: $RESTORE_ARCHIVE"
    [[ -z "$TARGET_VOLUME" ]] && die "Target volume not defined."

    if ! $DOCKER_CMD volume inspect "$TARGET_VOLUME" >/dev/null 2>&1; then
        info "Target volume '$TARGET_VOLUME' does not exist. Creating volume..."
        $DOCKER_CMD volume create "$TARGET_VOLUME" >/dev/null
    fi

    stop_associated_containers "$TARGET_VOLUME"

    if [[ "$NON_INTERACTIVE" == false ]]; then
        read -rp "Restoring into volume '$TARGET_VOLUME' will OVERWRITE existing data. Proceed? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && die "Restore procedure aborted by user." 0
    fi

    local archive_dir
    local archive_file
    archive_dir=$(dirname "$RESTORE_ARCHIVE")
    archive_file=$(basename "$RESTORE_ARCHIVE")

    info "Extracting $archive_file into volume '$TARGET_VOLUME'..."

    # Check if archive is GPG encrypted
    if [[ "$archive_file" =~ \.gpg$ ]]; then
        if ! command -v gpg >/dev/null 2>&1; then
            die "Archive is encrypted with GPG but 'gpg' utility is not installed."
        fi
        if [[ -z "$PASSPHRASE" ]]; then
            read -rsp "Enter passphrase to decrypt archive: " PASSPHRASE
            echo ""
        fi
        info "Decrypting GPG archive and extracting with zstd into volume '$TARGET_VOLUME'..."
        gpg --decrypt --batch --yes --passphrase-fd 0 "$RESTORE_ARCHIVE" <<< "$PASSPHRASE" |             $DOCKER_CMD run --rm -i -v "$TARGET_VOLUME":/volume_data alpine sh -c                 "apk add --no-cache zstd >/dev/null 2>&1 && rm -rf /volume_data/* /volume_data/..?* /volume_data/.[!.]* && tar -I 'zstd -d' -xf - -C /volume_data"
    else
        # Legacy tar.gz or tar.zst extraction auto-handling
        if [[ "$archive_file" =~ \.tar\.gz$ ]]; then
            $DOCKER_CMD run --rm                 -v "$TARGET_VOLUME":/volume_data                 -v "$archive_dir":/backup_dir                 alpine sh -c "rm -rf /volume_data/* /volume_data/..?* /volume_data/.[!.]* && tar xzf /backup_dir/$archive_file -C /volume_data"
        else
            $DOCKER_CMD run --rm                 -v "$TARGET_VOLUME":/volume_data                 -v "$archive_dir":/backup_dir                 alpine sh -c "apk add --no-cache zstd >/dev/null 2>&1 && rm -rf /volume_data/* /volume_data/..?* /volume_data/.[!.]* && tar -I 'zstd -d' -xf /backup_dir/$archive_file -C /volume_data"
        fi
    fi

    info "Restore operation successfully executed."
}

# --- Interactive TUI Workflow ---

interactive_menu() {
    echo "================================================="
    echo "    DVDBR v2.2 - Docker Volume Backup & Restore   "
    echo "================================================="
    echo "1) Backup Volume(s)"
    echo "2) Restore Volume"
    echo "3) Exit"
    read -rp "Select option [1-3]: " choice

    case "$choice" in
        1)
            MODE="backup"
            mapfile -t avail_vols < <($DOCKER_CMD volume ls --format "{{.Name}}")
            [[ ${#avail_vols[@]} -eq 0 ]] && die "No Docker volumes detected on host."

            echo -e "
Available Volumes:"
            select v in "${avail_vols[@]}" "ALL_VOLUMES" "CANCEL"; do
                case "$v" in
                    "CANCEL") exit 0 ;;
                    "ALL_VOLUMES") VOLUMES_TO_BACKUP=("${avail_vols[@]}"); break ;;
                    *) [[ -n "$v" ]] && VOLUMES_TO_BACKUP=("$v") && break ;;
                esac
            done

            read -rp "Enable Local Backup? [Y/n]: " sl
            [[ ! "$sl" =~ ^[Nn]$ ]] && SAVE_LOCAL=true
            if [[ "$SAVE_LOCAL" == true ]]; then
                read -rp "Local Backup Directory [default: ./backups]: " ld
                LOCAL_DIR="${ld:-./backups}"
                local exp_ld
                exp_ld=$(expand_path "$LOCAL_DIR")
                echo " -> Directory: $exp_ld [Available Space: $(get_avail_space_human "$exp_ld")]"
            fi

            read -rp "Enable Remote SSH Backup? [y/N]: " sr
            [[ "$sr" =~ ^[Yy]$ ]] && SAVE_REMOTE=true
            if [[ "$SAVE_REMOTE" == true ]]; then
                read -rp "Remote SSH Target (user@host:/remote/dir): " REMOTE_TARGET
                read -rp "SSH Key Path [default: ~/.ssh/id_rsa]: " sk
                SSH_KEY="${sk:-$HOME/.ssh/id_rsa}"

                echo -e "
Remote Transfer Protocol:"
                echo "1) Direct SSH Stream (Fastest, 0 local disk usage via pipe)"
                echo "2) Staging Rsync (Safest, writes temp file, resume capability)"
                echo "3) Staging SCP (Legacy fallback)"
                read -rp "Select protocol [1-3, default: 1]: " proto_choice

                case "$proto_choice" in
                    2) TRANSFER_PROTO="rsync" ;;
                    3) TRANSFER_PROTO="scp" ;;
                    *) TRANSFER_PROTO="stream" ;;
                esac

                if [[ "$TRANSFER_PROTO" == "rsync" || "$TRANSFER_PROTO" == "scp" ]]; then
                    read -rp "Staging Directory [default: /tmp]: " stg
                    STAGE_DIR="${stg:-/tmp}"
                    local exp_stg
                    exp_stg=$(expand_path "$STAGE_DIR")
                    echo " -> Staging Dir: $exp_stg [Available Space: $(get_avail_space_human "$exp_stg")]"
                fi
            fi

            read -rp "Enable Symmetric GPG Encryption (AES256)? [y/N]: " enc_ans
            if [[ "$enc_ans" =~ ^[Yy]$ ]]; then
                ENCRYPT=true
            fi

            execute_backup
            ;;
        2)
            MODE="restore"
            read -rp "Path to backup file (.tar.zst / .tar.gz / .gpg): " RESTORE_ARCHIVE
            read -rp "Target Docker Volume Name: " TARGET_VOLUME
            execute_restore
            ;;
        3) exit 0 ;;
        *) die "Invalid selection." ;;
    esac
}

# --- CLI Options Parser ---

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

DVDBR - Docker Volume Dump Backup & Restore Utility (v2.2.0)

Mode Options:
  -b, --backup              Run in backup mode.
  -r, --restore             Run in restore mode.

Backup Configuration:
  -v, --volume NAME         Docker volume to process (can be passed multiple times).
  -a, --all-volumes         Backup all existing Docker volumes.
  -l, --local-dir PATH      Save local backup to specified directory.
  -s, --remote TARGET       Remote target for SSH backup (user@host:/path).
  -i, --identity PATH       SSH Private Key path (default: ~/.ssh/id_rsa).
  -p, --proto PROTO         Remote transfer protocol: stream|rsync|scp (default: stream).
  --stage-dir PATH          Temporary directory for rsync/scp staging (default: /tmp).
  -e, --encrypt             Enable GPG symmetric encryption (AES256).
  --passphrase PASS         Passphrase for encryption/decryption (or set PASSPHRASE env var).
  --no-timestamp            Omit timestamp suffix from backup filename.

Restore Configuration:
  -f, --file PATH           Path to archive file (.tar.zst / .tar.gz / .gpg) for restoration.
  -t, --target-vol NAME     Target Docker volume name for restoration.

General Flags:
  -n, --no-stop             Do not stop containers during backup/restore.
  -y, --non-interactive     Run non-interactively (no prompts).
  -h, --help                Show this help message.

Examples:
  Interactive TUI:
    $SCRIPT_NAME

  Local zstd Backup with Symmetric GPG Encryption:
    $SCRIPT_NAME -b -v nextcloud_data -l /var/backups/docker -e --passphrase "Secret123" -y

  Remote SSH Atomic Stream with zstd & GPG Encryption:
    $SCRIPT_NAME -b -a -s backupuser@nas.local:/volume1/docker_backups -p stream -e --passphrase "Secret123" -y

  Restore encrypted zstd archive:
    $SCRIPT_NAME -r -f ./backups/nextcloud_data_20260330_120000.tar.zst.gpg -t nextcloud_data --passphrase "Secret123" -y
EOF
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--backup) MODE="backup" ;;
            -r|--restore) MODE="restore" ;;
            -v|--volume) VOLUMES_TO_BACKUP+=("$2"); shift ;;
            -a|--all-volumes) ALL_FLAG=true ;;
            -l|--local-dir) SAVE_LOCAL=true; LOCAL_DIR="$2"; shift ;;
            -s|--remote) SAVE_REMOTE=true; REMOTE_TARGET="$2"; shift ;;
            -i|--identity) SSH_KEY="$2"; shift ;;
            -p|--proto) TRANSFER_PROTO="$2"; shift ;;
            --stage-dir) STAGE_DIR="$2"; shift ;;
            -e|--encrypt) ENCRYPT=true ;;
            --passphrase) PASSPHRASE="$2"; shift ;;
            --no-timestamp) USE_TIMESTAMP=false ;;
            -f|--file) RESTORE_ARCHIVE="$2"; shift ;;
            -t|--target-vol) TARGET_VOLUME="$2"; shift ;;
            -n|--no-stop) STOP_CONTAINERS=false ;;
            -y|--non-interactive) NON_INTERACTIVE=true ;;
            -h|--help) usage ;;
            *) die "Unknown parameter: $1" ;;
        esac
        shift
    done

    check_docker_environment

    if [[ -z "$MODE" ]]; then
        if [[ "$NON_INTERACTIVE" == true ]]; then
            die "Non-interactive mode requires specifying --backup or --restore."
        fi
        interactive_menu
        exit 0
    fi

    if [[ "$MODE" == "backup" ]]; then
        if [[ "$ALL_FLAG" == true ]]; then
            mapfile -t VOLUMES_TO_BACKUP < <($DOCKER_CMD volume ls --format "{{.Name}}")
        fi
        [[ ${#VOLUMES_TO_BACKUP[@]} -eq 0 ]] && die "No volumes specified for backup. Use -v or -a."
        execute_backup
    elif [[ "$MODE" == "restore" ]]; then
        execute_restore
    fi
}

# --- Entry Point ---
parse_arguments "$@"
