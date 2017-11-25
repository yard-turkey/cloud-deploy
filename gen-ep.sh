#! /bin/bash
#
# 'gen-ep.sh' outputs enpoints json based on the supplied provider and instance filter.
#
# Usage:
#	./gen-ep.sh <provider> <instance-filter>
#	<provider> (required) name of cloud provider. Expect "aws" or "gce".
#	<filter>   (required) same value used as '--filter=' in the aws and gce cli.
# Example:
#	./gen-ep.sh gce jcope >gluster-ep.json
#

# Return an endpoint as a json string based on the provider's internal ips.
# Requires the global map INSTMAP.
# Note: the endpoints object name is hard-coded to "gluster-cluster" for now...
function make_ep_json() {
	local ip
	local subsets

	for ip in ${INSTMAP[INT_IPS]}; do
		subsets+="{'addresses':[{'ip':'$ip'}],'ports':[{'port':1}]},"
	done
	subsets="${subsets::-1}" # remove last comma
	local ep
	ep="
{
  'kind': 'Endpoints',
  'apiVersion': 'v1',
  'metadata': {
    'name': 'gluster-cluster'
  },
  'subsets': [
    $subsets
  ]
}"
	echo "$ep"
}


## main ##

cat <<END

   This script outputs endpoints json based on the supplied provider and filter, suitable for
   'kubectl create -f'.  Redirect output to capture the output in a file.
   Note: the name of the endpoints object is set to "gluster-cluster" so if a service is also used
   that service should have the same name.

   Usage: $0 <provider> <instance-filter>  eg. $0 aws jcope >ep.json

END

PROVIDER="$1"
if [[ -z "$PROVIDER" ]]; then
	echo "Missing required cloud-provider value" >&2
	exit 1
fi
PROVIDER="$(tr '[:upper:]' '[:lower:]' <<<"$PROVIDER")"
case $PROVIDER in
	aws|gce) ;;
	*) echo "Provider must be either aws or gce" >&2; exit 1 ;;
esac

FILTER="$2"
if [[ -z "$FILTER" ]]; then
	echo "Missing required instance-filter value" >&2
	exit 1
fi

echo "   Creating endpoints json for $PROVIDER ($FILTER)..."
echo

# source util functions based on provider
ROOT="$(dirname '${BASH_SOURCE}')"
if [[ ! -d "$ROOT/$PROVIDER" ]]; then
	echo "Missing $PROVIDER directory under $ROOT" >&2
	exit 1
fi
UTIL="$ROOT/$PROVIDER/util.sh"
if [[ ! -f "$UTIL" ]]; then
	echo "Missing $UTIL" >&2
	exit 1
fi
source $UTIL

# get internal ips from provider
rtn=$(util::get_instance_info $FILTER)
if (( $? != 0 )); then
	echo "failed to get $PROVIDER instance info:" >&2
	echo $rtn >&2
	exit 1
fi
declare -A INSTMAP=$rtn

# create endpoint json
json="$(make_ep_json)"

# output endpoints json to $stdout
echo "$json"

exit 0
