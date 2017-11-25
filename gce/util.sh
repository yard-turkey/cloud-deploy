#!/bin/bash
#
# GCE specific utility (helper) functions. Expected to live in the "gce/" directory.
# All providers are expected to support the following functions:
#	util::get_instance_info
#	util::xyzzy
#

# util::get_instance_info: based on the passed in instance-filter, return a map (as a string)
# which includes the following keys:
#	NAMES   - list of instance dns names
#	IDS     - list of ids (empty for gce)
#	ZONES   - list of gce zones
#	IPS_INT - list of cluster internal ips
#	IPS_EXT - list of external (public) ips
# Note: caller should 'declare -A map_var' before assigning to this function's return. Eg:
#	declare -A map=$(util::get_instance_info $filter)
#
function util::get_instance_info() {
	readonly filter="$1"
	readonly format='value(name,zone,networkInterfaces[].networkIP,networkInterfaces[].accessConfigs[0].natIP)'
	# ^ in key order: NAMES, ZONES, IPS_INT, IPS_EXT
	local info

	info="$(gcloud compute instances list --filter="$filter" --format="$format")"
	if (( $? != 0 )); then
		echo "error: failed to get gce info (NAMES, ZONES, IPs)" >&2
		return 1
	fi
	if [[ -z "$info" ]]; then
		echo "error: retrieved gce info is empty" >&2
		return 1
	fi
	# parse info into lists
	local rec; local names; local zones; local int_ips; local ext_ips
	while IFS= read -r rec; do
		names+="$(awk '{print $1}' <<<"$rec") "
		zones+="$(awk '{print $2}' <<<"$rec") "
		int_ips+="$(awk '{print $3}' <<<"$rec") "
		ext_ips+="$(awk '{print $4}' <<<"$rec") "
	done <<<"$info"
	local map
	map="([NAMES]='$names', [IDS]='', [ZONES]='$zones', [INT_IPS]='$int_ips', [EXT_IPS]='$ext_ips')"
	echo "$map"
	return 0
}

