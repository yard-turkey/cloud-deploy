#! /bin/bash

# Generate a 4 character string to be used as a suffix for
# GCP resources.
# Returns: Array of stings.
# Args:
#	1 - int, number of unique suffixes required.
function util::unique_id_arr {
	local num_ids=${1:-"4"}
	UUIDS="$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n $num_ids)"
}
