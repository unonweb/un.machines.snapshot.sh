#!/bin/bash

set -o errexit
set -o pipefail
#set -o nounset

# script location
export SCRIPT_PATH="$(readlink -f "${BASH_SOURCE}")"
export SCRIPT_DIR=$(dirname -- "$(readlink -f "${BASH_SOURCE}")")
export SCRIPT_DIR_NAME=$(dirname -- "$(readlink -f "${SCRIPT_DIR}")")
export SCRIPT_NAME=$(basename -- "$(readlink -f "${BASH_SOURCE}")")
export SCRIPT_PARENT=$(dirname "${SCRIPT_DIR}")
export CLEAR="\e[0m"
export BOLD="\e[1m"
export UNDERLINE="\e[4m"
export RED="\e[31m"
export GREEN="\e[32m"
export YELLOW="\e[33m"
export BLUE="\e[34m"
export MAGENTA="\e[35m"
export CYAN="\e[36m"
export GREY="\e[38;5;248m"

# STATIC
PATH_CONFIG="${SCRIPT_PARENT}/config.cfg"
BASE_DIR="/var/lib/machines"

# DEFAULTS
# just in case $PATH_CONFIG cannot be read
SNAPSHOTS_BASE="/.snapshots"
SNAPSHOTS_MAX_NUM=7

# IMPORTS
source "${PATH_CONFIG}"
source "${SCRIPT_DIR}/lib/is_value_in_array.sh"

function is_btrfs_subvolume {
	# must be run as root!
	btrfs subvolume show ${1} > /dev/null 2>&1
}

function get_subvolume_name { # ${mountpoint}
	local mountpoint=${1}
	echo $(btrfs subvolume show "${mountpoint}" 2>/dev/null | grep "Name:" | awk '{print $2}')
}

function cleanup_snapshots { # ${snapshot_path}
	# Function to clean up old snapshots
	# If there are more than ${SNAPSHOTS_MAX_NUM} snapshots, delete the oldest ones
	# must be run as root!
	
	local required=(
		SNAPSHOTS_BASE
		SNAPSHOTS_MAX_NUM
	)
	local snapshots_dir="${1}"
	local snapshots=("${snapshots_dir}/"*)
    local snapshot

	# check required vars
    for var in "${required[@]}"; do
        if [[ -z "${!var}" ]]; then
            echo "ERROR: ${var} is not set or is empty." >&2
			return 1
        fi
    done
	
	# check
	if [[ ${#snapshots[@]} -eq 0 ]]; then
		echo "ERROR: No snapshots found in ${snapshots_dir}"
		return 1
	fi

    if [ ${#snapshots[@]} -gt ${SNAPSHOTS_MAX_NUM} ]; then
        for snapshot in $(printf "%s\n" "${snapshots[@]}" | sort | head -n -${SNAPSHOTS_MAX_NUM}); do
			# sort: oldest up, newest down
			# head -n -3: exclude the last/the newest <num> files
			echo "Removing old snapshot: ${snapshot}"
            rm -rf "${snapshot}"
        done
	fi
}

function main {

	local machine_path
	local machines=()
	local machine
	local subvol_name
	local interactive_mode=0

	if [ "${UID}" -ne 0 ]; then
		echo "This script must be run as root."
		exit 1
	fi

	# parse args flags
	for arg in "${@}"; do
		case ${arg} in
		-i)
			interactive_mode=1
			;;
		esac
	done

	mapfile -t machines < <(machinectl list --no-legend | awk '{print $1}')

	echo
	echo "Running machines: ${machines[@]}"
	echo "Includes: ${INCLUDE_MACHINES[@]}"
	echo "Excludes: ${EXCLUDE_MACHINES[@]}"
	echo

	if [[ ${#machines[@]} -eq 0 ]]; then
		echo "Exiting ..."
		exit
	fi

	for machine in "${machines[@]}"; do
		local skip_iteration=false
		machine_path="${BASE_DIR}/${machine}"
		
		echo "---"
		echo -e "MACHINE: ${CYAN}${machine}${CLEAR}"

		if ! is_value_in_array ${machine} INCLUDE_MACHINES; then
			echo "Machine: ${machine} not included. Skipping ..."
			continue
		fi

		if is_value_in_array ${machine} EXCLUDE_MACHINES; then
			echo "Machine ${machine} excluded. Skipping ..."
			continue
		fi
		
		if [ ! -d "${machine_path}" ]; then
			echo "Not a directory: ${machine_path}"
			echo "Skipping ..."
			continue
		fi

		if ! is_btrfs_subvolume ${machine_path}; then
			echo "Not a btrfs subvolume: ${machine_path}"
			echo "Skipping ..."
			continue
		fi

		# subvolume name
		subvol_name=""
		subvol_name=$(btrfs subvolume show "${machine_path}" 2>/dev/null | grep "Name:" | awk '{print $2}')
		if [[ -z ${subvol_name} ]]; then
			echo "WARN: subvol_name is empty."
		fi

		echo -e "SUBVOL: ${CYAN}${subvol_name}${CLEAR}"

		# Stop machine
		if ((interactive_mode)); then
			echo "Stop container ${CYAN}${machine}${CLEAR}? (y|n)"
			read -p ">> "
			echo ""
			if [[ ${REPLY} != "y" ]]; then
				echo "Skipping ..."
				continue
			fi
		else
			echo "Stopping container: ${machine} ..."
			machinectl stop "${machine}"
		fi
		
		# Wait for the shutdown to complete
		sleep 1s
		local wait_count=0
		while machinectl status "${machine}" &>/dev/null; do
			# 0 if machine is running
			# 1 if machine is not running
			if ((wait_count == 6)); then
				echo "Aborting operation on machine ${machine} after waiting ${wait_count} seconds."
				skip_iteration=true
				break
			fi
			echo "Waiting for ${machine} to complete shutdown ... (${wait_count})"
			((wait_count++))
			sleep 1s
		done

		if ${skip_iteration}; then
        	continue
    	fi

		# Snapshot
		local snapshots_dir="${SNAPSHOTS_BASE}/${subvol_name:-${machine}}"
		local snapshot_path="${snapshots_dir}/$(date +%Y-%m-%d-%H%M%S)" # /.snapshots/@var-lib-machines-nextcloud-db/2025-12-05-131237
		
		if [ ! -d "${snapshots_dir}" ]; then
			mkdir -p "${snapshots_dir}"
		fi

		btrfs subvol snapshot "${machine_path}" "${snapshot_path}"

		# Cleanup old snapshots
		cleanup_snapshots "${snapshots_dir}"
		
		# Start the container again
		echo "Starting up container again: ${machine} ..."
		machinectl start "${machine}"
		
		if machinectl status "${machine}" &>/dev/null; then
			echo "Successfully restarted machine ${machine}"
		else
			echo "ERROR: Failed to start machine ${machine}"
		fi
	done

	echo "Done"
}

main ${@}