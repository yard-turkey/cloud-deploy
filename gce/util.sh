#!/bin/bash
#
# GCE specific utility (helper) functions. Expected to live in the "gce/" directory. Function names must
# be prefixed with "util::".

# All providers are expected to support the following functions:
#	util::get_instance_info
#	util::copy_file
#	util::remote_cmd



# Helpers #
# These functions implement lower level operations required for deploying
# and destroying Google Compute Engine instances.  These functions should be
# considered private, scoped to the provider.

function __init_network() {
	local fw_rule_allow_all="$GCP_USER-gluster-kubernetes-allow-all"
	echo "-- Checking for network $GCP_NETWORK"
	if ! gcloud compute networks describe "$GCP_NETWORK" &>/dev/null; then
		echo "-- Network not found. Creating network now."
		gcloud compute networks create "$GCP_NETWORK" --mode=auto || exit 1
	else
		echo "-- Using preconfigured network \"$GCP_NETWORK\" with firewall-rule \"$fw_rule_allow_all\"."
	fi
	return 0
}

function __init_firewall_rules() {
	echo "-- Checking for firewall-rule \"$fw_rule_allow_all\""
	if ! gcloud compute firewall-rules describe "$fw_rule_allow_all" &>/dev/null; then
		echo "-- Firewall-rule not found. Creating firewall-rule now."
		gcloud beta compute firewall-rules create "$fw_rule_allow_all" --direction=INGRESS \
			--network="$GCP_NETWORK" --action=ALLOW --rules=ALL --source-ranges=0.0.0.0/0 || exit 1
	fi
	return 0
}

function __create_instance_template() {
	echo "-- Creating instance template: $GK_TEMPLATE."
	util::exec_with_retry "gcloud compute instance-templates create ${GK_TEMPLATE} \
		--image=$CLUSTER_OS_IMAGE --image-project=$CLUSTER_OS_IMAGE_PROJECT \
		--machine-type=$MACHINE_TYPE --network=$GCP_NETWORK \
		--subnet=$GCP_NETWORK --region=$GCP_REGION  \
		--boot-disk-auto-delete --boot-disk-size=$NODE_BOOT_DISK_SIZE \
		--boot-disk-type=$NODE_BOOT_DISK_TYPE \
		--metadata-from-file=\"startup-script\"=$STARTUP_SCRIPT" $RETRY_MAX
	return 0
}

function __delete_instance_template() {
	GK_TEMPLATE="$GK_NODE_NAME"
	echo "-- Looking for old templates."
	if gcloud compute instance-templates describe $GK_TEMPLATE &>/dev/null; then
		echo "-- Instance template $GK_TEMPLATE already exists. Checking for dependent instance groups."
		# Cleanup old groups.  Templates cannot be deleted until they have no dependent groups..
		if gcloud compute instance-groups managed describe $GK_NODE_NAME \
			--zone=$GCP_ZONE &>/dev/null; then
			echo "-- Instance group $GK_NODE_NAME already exists, deleting before proceeding."
			if ! gcloud compute instance-groups managed delete $GK_NODE_NAME \
				--zone=$GCP_ZONE --quiet; then
				echo "-- Failed to delete instance group $GK_NODE_NAME."
				return 1
			fi
		fi
		echo "-- Deleting instance template $GK_TEMPLATE."
		if ! gcloud compute instance-templates delete $GK_TEMPLATE --quiet; then
			echo "-- Failed to delete instance-template $GK_TEMPLATE."
			return 1
		fi
	else
		echo "-- No pre-existing template found."
	fi
	return 0
}

function __create_instance_group() {
	echo "-- Creating instance group: $GK_NODE_NAME."
	util::exec_with_retry "gcloud compute instance-groups managed create $GK_NODE_NAME --zone=$GCP_ZONE \
		--template=$GK_TEMPLATE --size=$GK_NUM_NODES" $RETRY_MAX
	return 0
}

function __delete_instance_group() {}

function __create_master() {
	echo "-- Looking for old master instance: $GK_MASTER_NAME."
	if gcloud compute instances describe $GK_MASTER_NAME --zone=$GCP_ZONE &>/dev/null; then
		echo "-- Instance $GK_MASTER_NAME  already exists. Deleting it before proceeding."
		if ! gcloud compute instances delete $GK_MASTER_NAME --zone=$GCP_ZONE --quiet; then
			echo "-- Failed to delete instance $GK_MASTER_NAME"
			return 1
		fi
	else
		echo "-- No pre-existing master instance found."
	fi

	echo "-- Creating master instance: $GK_MASTER_NAME"
	util::exec_with_retry "gcloud compute instances create $GK_MASTER_NAME --boot-disk-auto-delete \
		--boot-disk-size=$NODE_BOOT_DISK_SIZE --boot-disk-type=$NODE_BOOT_DISK_TYPE \
		--image-project=$CLUSTER_OS_IMAGE_PROJECT --machine-type=$MASTER_MACHINE_TYPE \
		--network=$GCP_NETWORK --zone=$GCP_ZONE --image=$CLUSTER_OS_IMAGE \
		--metadata-from-file=\"startup-script\"=$STARTUP_SCRIPT" $RETRY_MAX \
	|| return 1
	return 0
}


function __create_secondary_disks() {
	echo "-- Creating RHGS block devices: ${OBJ_STORAGE_ARR[@]}"
	util::exec_with_retry "gcloud compute disks create ${OBJ_STORAGE_ARR[*]} \
		--size=$GLUSTER_DISK_SIZE --zone=$GCP_ZONE" $RETRY_MAX \
	|| return 1
	return 0
}

function __attach_secondary_disks() {
	for (( i=0; i < ${#OBJ_STORAGE_ARR[@]}; i++ )); do
		# Make several attach attempts per disk.
		util::exec_with_retry "gcloud compute instances attach-disk ${MINION_NAMES[$i]} \
			--disk=${OBJ_STORAGE_ARR[$i]} --zone=$GCP_ZONE" $RETRY_MAX \
		|| return 1
		util::exec_with_retry "gcloud compute instances set-disk-auto-delete ${MINION_NAMES[$i]} \
			--disk=${OBJ_STORAGE_ARR[$i]} --zone=$GCP_ZONE" $RETRY_MAX \
		|| return 1
	done
	return 0
}

function __delete_secondary_disks() {
	local disk_prefix="$GCP_USER-rhgs"
	OBJECT_STORAGE_ARR=()
	echo "-- Looking for old RHGS disks with prefix $disk_prefix."
	for (( i=0; i<${#MINION_NAMES[@]}; i++ )); do
		local disk="$disk_prefix-$i"
		OBJ_STORAGE_ARR[$i]="$disk"
		if gcloud compute disks describe $disk &>/dev/null; then
			echo "Found disk $disk. Deleting..."
			if ! gcloud compute disks delete $disk --zone=$GCP_ZONE --quiet; then
				echo "-- Failed to delete old RHGS disk \"$disk\""
				return 1
			fi
		fi
	done
	return 0
}

# Generic Utilities
# util::* functions are a set of operations that are implmented by each provider's
# library.  Similar to an interface, they MUST be implemented for each provider
# such that when they are called, they execute the required low level, provider
# specific operations that result in the expected outcomue (e.g. create_instances
# creates a set of instances in the given provider.)

function util::verify_client() {
	command -v gcloud || { echo "CLI client 'gcloud' not found."; return 1; }
	return 0
}

function util::create_instances() {
	# __init_network
	# __init_firewall_rules
	# __create_instance_template
	# __create_instance_group
	# __create_secondary_disks
	# __create_master
	return 0
}

function util::destroy_instances() {
	# __delete_instance_group
	# __delete_instance_template
	return 0
}

# util::get_instance_info: based on the passed in instance-filter and optional key(s), return a map
# (as a string) which includes one of more of the following keys:
#	NAMES       - list of instance dns names
#	IDS	    - empty for gce
#	ZONES       - list of zones
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
	local filter="$1"
	shift; local keys=($@) # array
	local query='value('

	(( ${#keys[@]} == 0 )) && keys=(NAMES ZONES PRIVATE_IPS PUBLIC_IPS) #all
	local key
	for key in ${keys[@]}; do
		case $key in
			NAMES)	     query+='name,';;
			ZONES)       query+='zone,';;
			PRIVATE_IPS) query+='networkInterfaces[].networkIP,';;
			PUBLIC_IPS)  query+='networkInterfaces[].accessConfigs[0].natIP,';;
			IDS)	     ;; # ignore but not an error
			*)	     echo "Unknown gce info key: $key" >&2; return 1;;
		esac
	done
	query="${query::-1}" # remove last comma
	query+=')'

	# retrieve gce instance info
	local info=()
	info=($(gcloud compute instances list --filter="$filter" --format="$query"))
	if (( $? != 0 )); then
		echo "error: failed to get gce info for keys: ${keys[@]}" >&2
		return 1
	fi
	if (( ${#info[@]}  == 0 )); then
		echo "error: retrieved gce info is empty, keys: ${keys[@]}" >&2
		return 1
	fi
	# parse info results into separate lists
	local i; local j; local names; local zones; local private_ips; local public_ips; local value
	for ((i=0; i<${#info[@]}; )); do
		for key in ${keys[@]}; do
			value="${info[$i]}"
			case $key in
				NAMES)       names+="$value ";;
				ZONES)       zones+="$value ";;
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
			ZONES)       map+="'$zones' ";;
			PRIVATE_IPS) map+="'$private_ips' ";;
			PUBLIC_IPS)  map+="'$public_ips' ";;
		esac
	done
        map+=')'
	echo "$map" # return json string
	return 0
}

# util::copy_file: use 'gcloud compute scp' to copy the passed-in source file to the
# supplied target file on the passed-in instance names. Returns 1 on errors.
# Args:
#   1=name of source file (on local host)
#   2=name of destination file (on instance)
#   3=list of instance names, quoted
#   4=list of zones, quoted.
#
function util::copy_file() {
	readonly src="$1"; readonly tgt="$2"
	readonly instances="$3"; readonly zones=($4) # instances and zones must be paired

	if [[ ! -f "$src" ]]; then
		echo "Source (from) file missing: \"$src\"" >&2
		return 1
	fi
	if [[ -z "$instances" ]]; then
		echo "Instance names missing" >&2
		return 1
	fi
	if [[ -z "$zones" ]]; then
		echo "Zones names missing" >&2
		return 1
	fi

	local inst; local zone; local err; local i=0
	for inst in $instances; do
		zone="${zones[$i]}"
		gcloud compute scp $src $inst:$tgt --zone=$zone
		err=$?
		if (( err != 0 )); then
			echo "gcloud compute error: failed to scp $src to $inst/$zone: $err" >&2
			return 1
		fi
		((i++))
	done
	return 0
}

# util::remote_cmd: execute the passed-in command on the target instance/zone.
#
function util::remote_cmd() {
	readonly inst="$1"; readonly zone="$2"
	shift 2; readonly cmd="$@"
	local err

	gcloud compute ssh $inst --command="$cmd" --zone=$zone
	err=$?
	if (( err != 0 )); then
		echo "error executing 'gcloud compute ssh $inst --command=$cmd --zone=$zone': $err" >&2
		return 1
	fi
	return 0
}
