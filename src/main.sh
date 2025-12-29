#!/bin/bash

# STATIC
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE}")"
SCRIPT_DIR=$(dirname -- "$(readlink -f "${BASH_SOURCE}")")
SCRIPT_DIR_NAME=$(dirname -- "$(readlink -f "${SCRIPT_DIR}")")
SCRIPT_NAME=$(basename -- "$(readlink -f "${BASH_SOURCE}")")
SCRIPT_PARENT=$(dirname "${SCRIPT_DIR}")
CLEAR="\e[0m"
BOLD="\e[1m"
UNDERLINE="\e[4m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
GREY="\e[38;5;248m"

# CONFIG & DEFAULTS
BASE_DIR="/var/lib/machines"
PATH_CONFIG="${SCRIPT_PARENT}/config.cfg"

if [[ -r ${PATH_CONFIG} ]]; then
	source "${PATH_CONFIG}"
else
	echo "<4>WARN: No config file found at ${PATH_CONFIG}. Using defaults ..."
	# DEFAULTS
	# just in case $PATH_CONFIG cannot be read
	SNAPSHOTS_BASE="/.snapshots"
	SNAPSHOTS_MAX_NUM=7
	INCLUDE_MACHINES=()
	EXCLUDE_MACHINES=()
fi

# IMPORTS
source "${SCRIPT_DIR}/lib/is_value_in_array.sh"

function is_btrfs_subvolume {
	# must be run as root!
	btrfs subvolume show ${1} > /dev/null 2>&1
}

function get_subvolume_name { # ${mountpoint}
	local mountpoint=${1}
	echo $(btrfs subvolume show "${mountpoint}" 2>/dev/null | grep "Name:" | awk '{print $2}')
}

function main {

	local machine_path
	local machines=()
	local machine
	local interactive_mode=0

	if [ "${UID}" -ne 0 ]; then
		echo "<3>ERROR: This script must be run as root."
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
	echo "<6>Machines: ${machines[@]}"
	echo "<6>Included: ${INCLUDE_MACHINES[@]}"
	echo "<6>Excluded: ${EXCLUDE_MACHINES[@]}"
	echo

	if [[ ${#machines[@]} -eq 0 ]]; then
		echo "<3>ERROR: No machines found. Exiting ..."
		exit 1
	fi

	for machine in "${machines[@]}"; do
		
		machine_path="${BASE_DIR}/${machine}"
		
		echo "<6>---"
		echo -e "<6>MACHINE: ${CYAN}${machine}${CLEAR}"

		if ! is_value_in_array ${machine} INCLUDE_MACHINES; then
			echo "<6>${machine} not included. Skipping ..."
			continue
		fi

		if is_value_in_array ${machine} EXCLUDE_MACHINES; then
			echo "<6>${machine} excluded. Skipping ..."
			continue
		fi
		
		if [ ! -d "${machine_path}" ]; then
			echo "<3>ERROR: Not a directory: ${machine_path}. Skipping ..."
			continue
		fi

		if ! is_btrfs_subvolume ${machine_path}; then
			echo "<3>ERROR: Not a btrfs subvolume: ${machine_path}. Skipping ..."
			continue
		fi

		# subvolume name
		local subvol_name=""
		subvol_name=$(btrfs subvolume show "${machine_path}" 2>/dev/null | grep "Name:" | awk '{print $2}')
		if [[ -z ${subvol_name} ]]; then
			echo "<4>WARN: subvol_name is empty."
		fi

		echo -e "<6>SUBVOL: ${CYAN}${subvol_name}${CLEAR}"

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
			echo "<6>Stopping container: ${machine} ..."
			machinectl stop "${machine}"
		fi
		
		# Wait for the shutdown to complete
		sleep 1
		local skip_iteration=false
		local wait_count=0
		local wait_count_max=6 # -> 6*2=12s

		while true; do
			if ! machinectl status "${machine}" &>/dev/null; then
				echo "<6>${machine} has stopped."
				break
			fi
			
			if ((wait_count == ${wait_count_max})); then
				echo "<3>ERROR: Aborting operation on machine ${machine} after waiting ${wait_count} seconds."
				skip_iteration=true
				break
			fi
			
			echo "<6>Waiting for ${machine} to complete shutdown ... (${wait_count}/${wait_count_max})"
			((wait_count++))
			sleep 2
		done

		if ${skip_iteration}; then
        	continue
    	fi

		# Snapshot
		local snapshots_dir="${SNAPSHOTS_BASE}/${subvol_name:-${machine}}" # /.snapshots/@var-lib-machines-nextcloud-db
		local snapshot_path="${snapshots_dir}/$(date +%Y-%m-%d-%H%M%S)" # /.snapshots/@var-lib-machines-nextcloud-db/2025-12-05-131237
		
		if [ ! -d "${snapshots_dir}" ]; then
			mkdir -p "${snapshots_dir}"
		fi

		btrfs subvol snapshot -r "${machine_path}" "${snapshot_path}"
		
		# Start the container again
		echo "<6>Starting up container again: ${machine} ..."
		machinectl start "${machine}"
		
		if machinectl status "${machine}" &>/dev/null; then
			echo "<6>Successfully restarted machine ${machine}"
		else
			echo "<3>ERROR: Failed to start machine ${machine}"
		fi
	done

	echo "<6>Done"
}

main ${@}