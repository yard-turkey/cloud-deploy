#! /bin/bash
#
# 'create-ep.sh' creates an endpoints resource on all aws and gce instances that match
# the <instance-filter> argument.
#
# Usage:
#	./create-ep.sh <instance-filter> [ep-name]
#	<filter>   (required) name or pattern uniquely identifying the target instance(s).
#       <ep-name>  (optional) name of endpoints object. Defaults to "gluster-cluster"
# Example:
#	./create-ep.sh jcope
#	./create-ep.sh jcope my-gluster


# create the endpoints object on the passed-in provider. The json endpoints file is expected to
# already live in /tmp on the target instances.
# Note: all references to 'zone' are accepted but *ignored* by aws helper funcs.
function create_ep() {
	readonly provider="$1"; readonly filter="$2"
	readonly ep_file='/tmp/endpoints.json'
	readonly cmd="kubectl create -f $ep_file"

	init::load_provider $provider || return 1
	local info="$(util::get_instance_info $filter NAMES ZONES)" # zones ignored by aws
	if (( $? != 0 )); then
		echo "failed to get $provider instance names" >&2
		return 1
	fi
	declare -A instances=$info

	local inst; local i=0; local zone
	local zones=(${instances[ZONES]}) # array
	for inst in ${instances[NAMES]}; do
		zone="${zones[$i]}"
		util::remote_cmd $inst $zone $cmd || return 1
		((i++))
	done
	return 0
}

## main ##

cat <<END >&2

   This script creates an endpoints resource on all instances across gce and aws that match the
   supplied filter. The endpoints object name can be supplied. If the endpoints name is omitted
   "gluster-cluster" is the default name.

   Usage: $0 <instance-filter> [endpoints-name]  eg. $0 jcope

END

ROOT="$(dirname '${BASH_SOURCE}')"
source $ROOT/init.sh || exit 1

FILTER="$1"
if [[ -z "$FILTER" ]]; then
	echo "Missing required instance-filter value" >&2
	exit 1
fi
EP_NAME="$2" # optional
EP_SCRIPT="$ROOT/gen-ep.sh"
if [[ ! -x "$EP_SCRIPT" ]]; then
	echo "endpoint generating script, $EP_SCRIPT, missing" >&2
	exit 1
fi

for provider in aws gce; do
	echo "   Create endpoints object for $provider ($FILTER)..." >&2
	eval "$EP_SCRIPT $provider $FILTER $EP_NAME --scp"
	if (( $? != 0 )); then
		echo "error executing $EP_SCRIPT script" >&2
		exit 1
	fi
	create_ep $provider $FILTER || exit 
done
exit 0
