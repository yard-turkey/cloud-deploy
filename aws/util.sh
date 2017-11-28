#!/bin/bash
#
# AWS specific utility (helper) functions. Expected to live in the "aws/" directory. Function names must
# be prefixed with "util::".
# All providers are expected to support the following functions:
#	util::get_instance_info
#	util::copy_file

# Helpers #
# These functions implement lower leverl operations required for deploying
# and destroying Google Compute Engine instances.

function __run_instance() {}

# Generic Utilities
# util::* functions are a set of operations that are implmented by each provider's
# library.  Similar to an interface, they MUST be implemented for each provider
# such that when they are called, they execute the required low level, provider
# specific operations that result in the expected outcomue (e.g. create_instances
# creates a set of instances in the given provider.)
function util::create_instances() {}

function util::destroy_instances() {}

# util::get_instance_info: based on the passed in instance-filter and optional key(s), return a map
# (as a string) which includes one of more of the following keys:
#	NAMES       - list of instance dns names
#	IDS         - list of ids
#	ZONES       - empty for aws
#	PRIVATE_IPS - list of cluster internal ips
#	PUBLIC_IPS  - list of external ips
# Note: all keys for all providers must be accepted, meaning do not cause an error, but should have
#       an empty value if not applicable to the cloud provider.
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
			ZONES)	     ;; # ignore but not an error
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
			NAMES)       map+="'$names' ";;
			IDS)         map+="'$ids' ";;
			PRIVATE_IPS) map+="'$private_ips' ";;
			PUBLIC_IPS)  map+="'$public_ips' ";;
		esac
	done
        map+=')'
	echo "$map" # return json string
	return 0
}

# util::copy_file: use scp to copy the passed-in source file to the supplied target file on the
# passed-in instance names. Returns 1 on errors.
# Args:
#   1=name of source file (on local host)
#   2=name of destination file (on instance)
#   3=list of instance names (quoted).
#
function util::copy_file() {
	readonly src="$1"; readonly tgt="$2"; readonly instances="$3"
	readonly aws_user='centos'

	if [[ ! -f "$src" ]]; then
		echo "Source (from) file missing: \"$src\"" >&2
		return 1
	fi
	if [[ -z "$instances" ]]; then
		echo "Instance names missing" >&2
		return 1
	fi

	local inst; local err
	for inst in $instances; do
		scp $src $aws_user@$inst:$tgt
		err=$?
		if (( err != 0 )); then
			echo "scp error: failed to scp $src to $inst: $err" >&2
			return 1
		fi
	done
	return 0
}

# util::remote_cmd: execute the passed-in command on the target instance via sudo.
#
function util::remote_cmd() {
	readonly inst="$1"
	shift; readonly cmd="sudo $@"
	readonly aws_user='centos'
	local err

	ssh -t $aws_user@$inst "$cmd"
	err=$?
	if (( err != 0 )); then
		echo "error executing 'ssh -t $aws_user@$inst \"$cmd\"': $err" >&2
		return 1
	fi
	return 0
}

