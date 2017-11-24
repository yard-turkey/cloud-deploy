#! /bin/bash
#
# 'gen-ep.sh' generates an enpoints json file based on the supplied provider and instance filter.
#
# Usage:
#	./gen-ep.sh <provider> <instance-filter>
#	<provider> (required) name of cloud provider. Expect "aws" or "gce".
#	<filter>   (required) same value used as '--filter=' in the aws and gce cli.
#	<filename> (optional) the name of the generated endpoints json file. If omitted
#		   the name "$provider-ep.json" is used.
# Example:
#	./gen-ep.sh gce jcope 
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

   This script generates an endpoints json file based on the supplied provider and filter, suitable
   for 'kubectl create -f'. The endpoints file name can be specified or will default to
	"<provider>-ep.json"
   The name of the endpoints object is set to "gluster-cluster" so if a service is also used that
   service should have the same name.

   Usage: $0 <provider> <instance-filter> [json-filename]  eg. $0 aws jcope

END

PROVIDER="$1"
if [[ -z "$PROVIDER" ]]; then
	echo "Missing required cloud-provider value"
	exit 1
fi
PROVIDER="$(tr '[:upper:]' '[:lower:]' <<<"$PROVIDER")"
case $PROVIDER in
	aws|gce) ;;
	*) echo "Provider must be either aws or gce"; exit 1 ;;
esac

FILTER="$2"
if [[ -z "$FILTER" ]]; then
	echo "Missing required instance-filter value"
	exit 1
fi
FNAME="$3"
[[ -z "$FNAME" ]] && FNAME="${PROVIDER}-ep.json"

echo "   Creating endpoints file \"$FNAME\" for $PROVIDER ($FILTER)..."
echo

# source util functions based on provider
ROOT="$(dirname '${BASH_SOURCE}')"
if [[ ! -d "$ROOT/$PROVIDER" ]]; then
	echo "Missing $PROVIDER directory under $ROOT"
	exit 1
fi
UTIL="$ROOT/$PROVIDER/util.sh"
if [[ ! -f "$UTIL" ]]; then
	echo "Missing $UTIL"
	exit 1
fi
source $UTIL

# get internal ips from provider
rtn=$(util::get_instance_info $FILTER)
if (( $? != 0 )); then
	echo "failed to get $PROVIDER instance info:"
	echo $rtn
	exit 1
fi
declare -A INSTMAP=$rtn

# create endpoint json
json="$(make_ep_json)"

# write json to file
echo "$json" >$FNAME

echo "Successfully created \"$FNAME\""
echo
exit 0
