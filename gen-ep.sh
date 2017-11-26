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

	for ip in ${INSTMAP[PRIVATE_IPS]}; do
		subsets+="{'addresses':[{'ip':'$ip'}],'ports':[{'port':1}]},"
	done
	subsets="${subsets::-1}" # remove last comma
	local ep
	ep="\
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

cat <<END >&2

   This script outputs endpoints json based on the supplied provider and filter, suitable for
   'kubectl create -f'.  Redirect output to capture the output in a file.
   Note: the name of the endpoints object is set to "gluster-cluster" so if a service is also used
   that service should have the same name.

   Usage: $0 <provider> <instance-filter>  eg. $0 aws jcope >ep.json

END

# source util funcs based on provider
source init.sh || exit 1

PROVIDER="$1"
init::load_provider $PROVIDER || exit 1

FILTER="$2"
if [[ -z "$FILTER" ]]; then
	echo "Missing required instance-filter value" >&2
	exit 1
fi

echo "   Creating endpoints json for $PROVIDER ($FILTER)..." >&2
echo >&2

# get internal ips from provider
declare -A INSTMAP=$(util::get_instance_info $FILTER PRIVATE_IPS)
if (( $? != 0 )); then
	echo "failed to get $PROVIDER instance info:" >&2
	exit 1
fi

# create endpoint json
json="$(make_ep_json)"

# output endpoints json to $stdout
echo "$json"

exit 0
