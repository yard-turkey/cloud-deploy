#! /bin/bash

# Verify gloud installed.
function gce_util::verify_gcloud() {
	echo "-- Verifying gcloud."
	if ! gcloud --version &> /dev/null; then
		echo "-- Failed to execute gcloud --version."
		return 1
	fi
	return 0
}

# Cleanup old templates.
function gce_util::delete_templates() {
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

# Create a network for the cluster and open all ports on all protocols.
function gce_util::create_network() {
	local fw_rule_allow_all="$GCP_USER-gluster-kubernetes-allow-all"
	echo "-- Checking for network $GCP_NETWORK"
	if ! gcloud compute networks describe "$GCP_NETWORK" &>/dev/null; then
		echo "-- Network not found. Creating network now."
		gcloud compute networks create "$GCP_NETWORK" --mode=auto || exit 1
	else
		echo "-- Using preconfigured network \"$GCP_NETWORK\" with firewall-rule \"$fw_rule_allow_all\"."
	fi
	echo "-- Checking for firewall-rule \"$fw_rule_allow_all\""
	if ! gcloud compute firewall-rules describe "$fw_rule_allow_all" &>/dev/null; then
		echo "-- Firewall-rule not found. Creating firewall-rule now."
		gcloud beta compute firewall-rules create "$fw_rule_allow_all" --direction=INGRESS \
			--network="$GCP_NETWORK" --action=ALLOW --rules=ALL --source-ranges=0.0.0.0/0 || exit 1
	fi
}

# Create new template.
function gce_util::create_template() {
	echo "-- Creating instance template: $GK_TEMPLATE."
	util::exec_with_retry "gcloud compute instance-templates create ${GK_TEMPLATE} \
		--image=$CLUSTER_OS_IMAGE --image-project=$CLUSTER_OS_IMAGE_PROJECT \
		--machine-type=$MACHINE_TYPE --network=$GCP_NETWORK \
		--subnet=$GCP_NETWORK --region=$GCP_REGION  \
		--boot-disk-auto-delete --boot-disk-size=$NODE_BOOT_DISK_SIZE \
		--boot-disk-type=$NODE_BOOT_DISK_TYPE \
		--metadata-from-file=\"startup-script\"=$STARTUP_SCRIPT" $RETRY_MAX
}

# Create new instance group.
function gce_util::create_group() {
	echo "-- Creating instance group: $GK_NODE_NAME."
	util::exec_with_retry "gcloud compute instance-groups managed create $GK_NODE_NAME --zone=$GCP_ZONE \
		--template=$GK_TEMPLATE --size=$GK_NUM_NODES" $RETRY_MAX
}

# Create master Instance (delete old instance if present).
function gce_util::create_master() {
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

# Set the internal and external ip arrays for the master node and all minions.
# Sets: MASTER_IPS, MINION_NAMES, MINION_IPS, and HOSTS global vars.
# Note: the MINION_IPS map is not yet referenced but remains for future usage.
function gce_util::master_minions_ips() {
	echo "-- Setting global master and minion internal and external ip addresses."
	# format: (internal-ip external-ip)
	MASTER_IPS=($(gcloud compute instances list --filter="zone:($GCP_ZONE) name:($GK_MASTER_NAME)" \
		--format="value(networkInterfaces[0].networkIP,\
		  networkInterfaces[0].accessConfigs[0].natIP)"))
	if (( ${#MASTER_IPS[@]} == 0 )); then
		echo "Failed to get master node $GK_MASTER_NAME's ip addresses."
		return 1
	fi

	# Make a single call to gcloud to get all minion info
	# format: (hostname internal-ip external-ip...)
	local minions=($(gcloud compute instances list --filter="zone:($GCP_ZONE) name:($GK_NODE_NAME)" \
		--format="value(name,networkInterfaces[0].networkIP,\
		  networkInterfaces[0].accessConfigs[0].natIP)"))
	if (( ${#minions[@]} == 0 )); then
		echo "Failed to get minions."
		return 1
	fi

	# set MINION_NAMES and HOSTS arrays, and MINION_IPS map
	declare -A MINION_IPS=() # key=hostname, value="internal-ip external-ip"
	HOSTS=() # format: (internal-ip minion-name internal-ip minion-name...)
	MINION_NAMES=() # format: (name name..)
	size=${#minions[@]}
	for ((i=0; i<=$size-3; i+=3 )); do
		host="${minions[$i]}"
		int_ip=${minions[$i+1]} # internal ip
		ext_ip=${minions[$i+2]} # external ip
		MINION_IPS[$host]="$int_ip $ext_ip"
		MINION_NAMES+=($host)
		HOSTS+=($int_ip $host)
	done
	return 0
}

# Clean up old RHGS disks.
function gce_util::delete_rhgs_disks() {
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

# Create and attach RHGS disks
function gce_util::create_attach_disks() {
	echo "-- Creating RHGS block devices: ${OBJ_STORAGE_ARR[@]}"
	util::exec_with_retry "gcloud compute disks create ${OBJ_STORAGE_ARR[*]} \
		--size=$GLUSTER_DISK_SIZE --zone=$GCP_ZONE" $RETRY_MAX \
	|| return 1

	echo "-- Attaching RHGS disks to nodes."
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
