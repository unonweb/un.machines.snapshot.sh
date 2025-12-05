function is_value_in_array { # $value array
	local value="${1}"
  	local -n _array=${2}
	local item
	
  	for item in "${_array[@]}"; do

    	#echo "Check ${item}"

    	if [[ "${item}" == "${value}" ]]; then
      		return 0 # Found
    	fi
		
  	done
  	
	return 1 # Not found
}