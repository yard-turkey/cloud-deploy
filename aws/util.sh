#!/bin/bash
#
# AWS specific utility (helper) functions. Expected to live in the "aws/" directory.
# All providers are expected to support the following functions:
#	util::get_instance_info
#	util::xyzzy
#

# util::get_instance_info: based on the passed in instance-filter, return a map (as a string)
# which includes the following keys:
#	NAMES   - list of instance dns names
#	IDS     - list of ids
#	ZONES   - list of zones (empty for aws)
#	IPS_EXT - list of external (public) ips
#	IPS_INT - list of cluster internal ips
# Note: caller should 'declare -A map_var' before assigning to this function's return. Eg:
#	declare -A map=$(util::get_instance_info $filter)
#
function util::get_instance_info() {
	readonly filter="Name=tag:Name,Values='*$1*'"
	readonly query='Reservations[*].Instances[*].[PublicDnsName,InstanceId,PrivateIpAddress,PublicIpAddress]'
	# ^ in key order: NAMES, IDS, IPS_EXT, IPS_INT
	local info

	info="$(aws ec2 --output text describe-instances --filter $filter --query $query)"
	if (( $? != 0 )); then
		echo "error: failed to get aws info (NAMES, IDs, IPs)" >&2
		return 1
	fi
	if [[ -z "$info" ]]; then
		echo "error: retrieved aws info is empty" >&2
		return 1
	fi
	# parse info into lists
	local rec; local names; local ids; local int_ips; local ext_ips
	while IFS= read -r rec; do
		names+="$(awk '{print $1}' <<<"$rec") "
		ids+="$(awk '{print $2}' <<<"$rec") "
		int_ips+="$(awk '{print $3}' <<<"$rec") "
		ext_ips+="$(awk '{print $4}' <<<"$rec") "
	done <<<"$info"
	local map
	map="([NAMES]='$names', [IDS]='$ids', [ZONES]='', [INT_IPS]='$int_ips', [EXT_IPS]='$ext_ips')"
	echo "$map"
	return 0
}

