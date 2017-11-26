#! /bin/bash
#
# 'gen-ep.sh' outputs enpoints json based on the supplied provider and instance filter.
#
# Usage:
#	./gen-ep.sh [--scp] <provider> <instance-filter>
#	<provider> (required) name of cloud provider. Expect "aws" or "gce".
#	<filter>   (required) same value used as '--filter=' in the aws and gce cli.
#	--scp	   if present, copy json file to provider instances. If supplied then output
#		   redirection should not be used.
# Example:
#	./gen-ep.sh gce jcope >gluster-ep.json
#	./gen-ep.sh aws jcope --scp
#


# Parse script options. Non-option arguments are parsed my the main script block.
# Sets global option names to 1 if present.
function parse_options() {
	local opts='scp'; local parsed

	parsed="$(getopt --long $opts -- $@)"
	if (( $? != 0 )); then
		echo "command parsing error"
		return 1
	fi

	eval set -- "$parsed"
	while true; do
		case "$1" in
			--scp)	SCP=1; shift; continue;;
			--)	shift; break
		esac
	done
	return 0
}


# Return endpoints as a json string based on the provider's internal (private) ips.
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
   'kubectl create -f'.  Redirect output to capture the output in a file, or instead use --scp
   to copy the json file to "/tmp/endpoints.json" on each instance.
   Note: the name of the endpoints object is set to "gluster-cluster" so if a service is also used
   that service should have the same name.

   Usage: $0 [--scp] <provider> <instance-filter>  eg. $0 aws jcope >ep.json

END

# source util funcs based on provider
source init.sh || exit 1

parse_options "$@" || exit 1

PROVIDER="$1"
init::load_provider $PROVIDER || exit 1

FILTER="$2"
if [[ -z "$FILTER" ]]; then
	echo "Missing required instance-filter value" >&2
	exit 1
fi

(( SCP )) && EP_FILE='/tmp/endpoints.json'

echo "   Create endpoints json for $PROVIDER ($FILTER)..." >&2
(( SCP )) &&
	echo "   and copy file as \"$EP_FILE\" on each provider instance..." >&2
echo >&2

# get internal ips from provider, and optionally instance names
INSTKEYS='PRIVATE_IPS'
(( SCP )) && INSTKEYS+=' NAMES'
[[ "$PROVIDER" == 'gce' ]] && INSTKEYS+=' ZONES'
info=$(util::get_instance_info $FILTER $INSTKEYS)
if (( $? != 0 )); then
	echo "failed to get $PROVIDER instance info:" >&2
	exit 1
fi
declare -A INSTMAP=$info

# create endpoint json
json="$(make_ep_json)"

# scp ep file or just output contents?
if (( SCP )); then
	TMP_EP="/tmp/${PROVIDER}-ep.json"
	echo "$json" >$TMP_EP
	util::copy_file $TMP_EP $EP_FILE "${INSTMAP[NAMES]}" "${INSTMAP[ZONES]}" || exit 1
	# note ZONES is empty for aws
	rm -f $TMP_EP
	exit 0
fi
# output to $stdout
echo "$json"

exit 0
