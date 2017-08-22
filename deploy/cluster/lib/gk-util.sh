#! /bin/bash

# Generate a 4 character string to be used as a suffix for
# GCP resources.
# Returns: Array of stings.
# Args:
#	1 - int, number of unique suffixes required.
function unique_id_arr {
	NUM_IDS=${1:-"4"}
	ARR=( "$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n $NUM_IDS)" )
	return $ARR
}
