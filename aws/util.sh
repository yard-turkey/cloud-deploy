#!/bin/bash
#
# AWS specific utility (helper) functions. Expected to live in the "aws/" directory. Function names must
# be prefixed with "util::".
# All providers are expected to support the following functions:
#	util::get_instance_info
#

# util::get_instance_info: based on the passed in instance-filter and optional key(s), return a map
# (as a string) which includes one of more of the following keys:
#	NAMES       - list of instance dns names
#	IDS         - list of ids
#	PRIVATE_IPS - list of cluster internal ips
#	PUBLIC_IPS  - list of external ips
# Args: 1=instance-filter (required), 2+=zero or more map keys separated by spaces. If no key is
#       provided then all key values are returned.
# Note: caller should 'declare -A map_var' before assigning to this function's return. Eg:
#	declare -A map=$(util::get_instance_info $filter)
#
function util::get_instance_info() {
	local filter="Name=tag:Name,Values='*$1*'"
	shift; local keys=($@) # array
	local query="Reservations[*].Instances[*].["

	(( ${#keys[@]} == 0 )) && keys=(NAMES IDS PRIVATE_IPS PUBLIC_IPS) #all
	local key
	for key in ${keys[@]}; do
		case $key in
			NAMES)	     query+='PublicDnsName,';;
			IDS)         query+='InstanceId,';;
			PRIVATE_IPS) query+='PrivateIpAddress,';;
			PUBLIC_IPS)  query+='PublicIpAddress,';;
			*)	     echo "Unknown aws info key: $key" >&2; return 1;;
		esac
	done
	query="${query::-1}" # remove last comma
	query+=']'
	
	# retrieve aws ec2 info
	local info=()
	info=($(aws ec2 --output text describe-instances --filter="$filter" --query="$query"))
	if (( $? != 0 )); then
		echo "error: failed to get aws info for keys: ${keys[@]}" >&2
		return 1
	fi
	if (( ${#info[@]}  == 0 )); then
		echo "error: retrieved aws info is empty, keys: ${keys[@]}" >&2
		return 1
	fi
	# parse info results into separate lists
	local i; local j; local names; local ids; local private_ips; local public_ips; local value
	for ((i=0; i<${#info[@]}; )); do
		for key in ${keys[@]}; do
			value="${info[$i]}"
			case $key in
				NAMES)       names+="$value ";;
				IDS)         ids+="$value ";;
				PRIVATE_IPS) private_ips+="$value ";;
				PUBLIC_IPS)  public_ips+="$value ";;
			esac	
			((i++))
		done
	done

	# construct map
	local map='('
	for key in ${keys[@]}; do
		map+="[$key]="
		case $key in
			NAMES)       map+="'$names', ";;
			IDS)         map+="'$ids', ";;
			PRIVATE_IPS) map+="'$private_ips', ";;
			PUBLIC_IPS)  map+="'$public_ips', ";;
		esac
	done
	map="${map::-2}" # remove last ", "
        map+=')'
	echo "$map" # return json string
	return 0
}

