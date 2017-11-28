#! /bin/bash
#
# 'create-ep.sh' creates an endpoints resource on all aws and gce instances that match
# the <instance-filter> parameter.
#
# Usage:
#	./create-ep.sh <instance-filter>
#	<filter>   (required) same value used as '--filter=' in the aws and gce cli.
# Example:
#	./create-ep.sh jcope


# create the endpoints object on the passed-in provider. The json endpoints file is expected to
# already live in /tmp in each target instance.
function create_ep() {
	readonly provider="$1"; readonly filter="$2"
	readonly ep_file='/tmp/endpoints.json'
	readonly cmd="kubectl create -f $ep_file"

	init::load_provider $provider || return 1
	local info="$(util::get_instance_info $filter NAMES ZONES)"
	if (( $? != 0 )); then
		echo "failed to get $provider instance names" >&2
		return 1
	fi
	declare -A instances=$info

	local inst; local i=0; local zone # only needed for gce
	local zones=(${instances[ZONES]}) # array, empty for aws
	for inst in ${instances[NAMES]}; do
		zone="${zones[$i]}" # empty for aws
		util::remote_cmd $inst $zone $cmd || return 1
		((i++))
	done
	return 0
}

## main ##

cat <<END >&2

   This script creates the endpoints resource on all instances that match the supplied filter.
   Note: the name of the endpoints object is set to "gluster-cluster" so if a service is also used
   that service should have the same name.

   Usage: $0 <instance-filter>  eg. $0 jcope

END

ROOT="$(dirname '${BASH_SOURCE}')"
source $ROOT/init.sh || exit 1

FILTER="$1"
if [[ -z "$FILTER" ]]; then
	echo "Missing required instance-filter value" >&2
	exit 1
fi
EP_SCRIPT="$ROOT/gen-ep.sh"
if [[ ! -f "$EP_SCRIPT" ]]; then
	echo "endpoint generating script, $EP_SCRIPT, missing" >&2
	exit 1
fi

for provider in aws gce; do
	echo "   Create endpoints object for $provider ($FILTER)..." >&2
	eval "$EP_SCRIPT $provider $FILTER --scp"
	if (( $? != 0 )); then
		echo "error executing $EP_SCRIPT script" >&2
		exit 1
	fi
	create_ep $provider $FILTER || exit 
done
exit 0
