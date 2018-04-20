#! /bin/bash
#
# 'gk-up.sh', and its companion startup script 'do-startup.sh', create a gce cluster customized using a 
# rhel 7 image with gluster, heketi, git, helm, kubernetes, service-catalog, etc installed. The startup
# script creates a file named "/root/__SUCCESS" once it has completed. If the gce cluster is running it
# will be shut down (this script is idempotent.) A custom cns s3 service broker is also installed.
#
# Args:
#		-y to bypass hitting a key to acknowlege seeing the displayed config info.
#       The default is to prompt the user to continue.
#		-i Deploy GCE instances and stop.  Startup script will still install packages and dependencies on all VMs.
#          DO NOT deploy k8s, gluster-kubernetes (including S3 component), or the CNS Objet Broker
#		-g Deploy gluster-kubernetes and stop.
#          DO NOT install S3 components or the CNS Object Broker
#		-s Deploy gluster-kubernetes, S3 components and stop.
#          DO NOT install CNS Object Broker
# Note: lowercase vars are local to functions. Uppercase vars are global.

set -euo pipefail

# Print help
function print_help() {
	echo "Gluster-Kubernetes GCE deployment script."
	echo "-y to bypass hitting a key to acknowlege seeing the displayed config info."
	echo "   The default is to prompt the user to continue."
	echo "-i Deploy GCE instances and stop.  Startup script will still install packages and dependencies on all VMs."
	echo "   DO NOT deploy k8s, gluster-kubernetes (including S3 component), or the CNS Objet Broker"
	echo "-g Deploy gluster-kubernetes and stop."
	echo "   DO NOT install S3 components or the CNS Object Broker"
	echo "-s Deploy gluster-kubernetes, S3 components and stop."
	echo "   DO NOT install CNS Object Broker"
}

# Parse out -y arg if present.
function parse_args() {
	# 0=true, 1=false
	DO_CONFIG_REVIEW=0
	INSTALL_GLUSTER=0
	INSTALL_OBJECT=0
	INIT_KUBE=0
	while getopts yYnNigsh o; do
		case "$o" in
		y|Y)
			DO_CONFIG_REVIEW=1
			;;
		n|N)    # default
			;;
		i)		# do not initialize anything.  allow the start up script to run then exit
			INIT_KUBE=1
			;&	
		g)		# bare cluster:  do not install gluster; fallthrough and do not install object.
			INSTALL_GLUSTER=1
			;&
		s)		# only gluster: do not install object frontend
			INSTALL_OBJECT=1
			;;
		h)
			print_help
			return 2 
			;;
		[?])
			print_help
			return 1
			;;
		esac
	done
	return 0
}


# Verify gloud installed.
function verify_gcloud() {
	echo "-- Verifying gcloud."
	if ! gcloud --version &> /dev/null; then
		echo "-- Failed to execute gcloud --version."
		return 1
	fi
	return 0
}

# Cleanup old templates.
function delete_templates() {
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
function create_network() {
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
function create_template() {
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
function create_group() {
	echo "-- Creating instance group: $GK_NODE_NAME."
	util::exec_with_retry "gcloud compute instance-groups managed create $GK_NODE_NAME --zone=$GCP_ZONE \
		--template=$GK_TEMPLATE --size=$GK_NUM_NODES" $RETRY_MAX
}

# Create master Instance (delete old instance if present).
function create_master() {
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
function master_minions_ips() {
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
function delete_rhgs_disks() {
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
function create_attach_disks() {
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

# Waiting for startup script to complete.
# Note: we wait longer for the master and nodes to be ready.
function wait_on_master() {
	echo "-- Waiting for start up scripts to complete on $GK_MASTER_NAME."
	util::exec_with_retry "gcloud compute ssh  $GK_MASTER_NAME --zone=$GCP_ZONE \
		--command='sudo ls /root/__SUCCESS 2>/dev/null'" 50
}

# Wait for the minion node startup script to complete and attach kube minions to master.
function join_minions() {
	echo "-- Attaching minions to kube master." 
	local token="$(gcloud compute ssh $GK_MASTER_NAME --zone=$GCP_ZONE --command='sudo kubeadm token list' | \
		awk 'NR>1{print $1}')"
	local join_cmd="sudo kubeadm join --ignore-preflight-errors=all --discovery-token-unsafe-skip-ca-verification --token $token ${MASTER_IPS[0]}:6443" # internal ip
	for node in "${MINION_NAMES[@]}"; do
		echo "-- Waiting for start up scripts to complete on node $node."
		util::exec_with_retry "gcloud compute ssh --zone=$GCP_ZONE $node \
			--command='sudo ls /root/__SUCCESS 2>/dev/null'" 50 \
		|| return 1
		# Join kubelet to master
		echo "-- Executing '$join_cmd' on node $node."
		util::exec_with_retry "gcloud compute ssh $node --zone=$GCP_ZONE --command='${join_cmd}'" $RETRY_MAX \
		|| return 1
	done
	return 0
}

# Update master node's /etc/hosts file.
function update_etc_hosts() {
	echo "-- Update master's hosts file:"
	echo "   Appending \"${HOSTS[*]}\" to $GK_MASTER_NAME's /etc/hosts."
	#todo: this is not working
	gcloud compute ssh "$GK_MASTER_NAME" --zone="$GCP_ZONE" \
		--command="sudo su; printf '%s  %s  # Added by gk-up\n' ${HOSTS[*]} >>/etc/hosts"
}

# Build gluster-Kubernetes topology file.
function create_topology() {
	echo "-- Generating gluster-kubernetes topology.json"
	local topology_path="$(util::gen_gk_topology ${HOSTS[*]})"
	echo "-- Sending topology to $GK_MASTER_NAME:/tmp/"
	util::exec_with_retry "gcloud compute scp --zone=$GCP_ZONE $topology_path $GCP_USER@$GK_MASTER_NAME:/tmp/" $RETRY_MAX \
	|| return 1
	echo "-- Finding gk-deploy.sh on $GK_MASTER_NAME"
	GK_DEPLOY="$(gcloud compute ssh $GK_MASTER_NAME --zone=$GCP_ZONE \
		--command='sudo find /root/ -type f -wholename *deploy/gk-deploy')"
	if (( $? != 0 )) || [[ -z "$GK_DEPLOY" ]]; then
		echo -e "-- Failed to find gk-deploy cmd on master. ssh to master and do:\n   find /root/ -type f -wholename *deploy/gk-deploy"
		return 1
	fi
	return 0
}

# Run the gk-deploy script on master.
function run_gk_deploy() {
	echo "-- Running gk-deploy.sh on $GK_MASTER_NAME:"
	local s3_opts="--object-account=$GCP_USER --object-user=$GCP_USER --object-password=$GCP_USER"
	if [ $INSTALL_OBJECT != 0  ]; then
		s3_opts=""
	fi
	echo "   $GK_DEPLOY -gvy --no-block $s3_opts /tmp/topology.json"
	printf "\n\nBEGIN DEBUG"
	set -x
	gcloud compute ssh "$GK_MASTER_NAME" --zone="$GCP_ZONE" \
        --command="sudo $GK_DEPLOY -gvy --no-block ${s3_opts} /tmp/topology.json"
	set +x
	printf "\n\n END DEBUG"
	if (( $? != 0 )); then
		echo "-- Failed to run $GK_DEPLOY on master $GK_MASTER_NAME"
		return 1
	fi
	return 0
}

# Expose gluster s3.
function expose_gluster_s3() {
	util::exec_with_retry "gcloud compute ssh $GK_MASTER_NAME --zone=$GCP_ZONE \
		--command='sudo kubectl expose deployment gluster-s3-deployment --type=NodePort \
		  --port=8080'" $RETRY_MAX
}

# Install CNS Broker.
function install_cns-broker() {
	local svc_name="broker-cns-object-broker-node-port"
	local ns="broker"
	local chart="cns-object-broker/chart"
	echo "-- Deploying CNS Object Broker"
	util::exec_with_retry "gcloud compute ssh $GK_MASTER_NAME --zone=$GCP_ZONE \
		--command='sudo helm install $chart --name broker --namespace $ns'" \
		$RETRY_MAX \
	|| return 1
	BROKER_PORT=$(gcloud compute ssh $GK_MASTER_NAME \
		--command="sudo kubectl get svc -n $ns $svc_name \
		  -o jsonpath={.'spec'.'ports'[0].'nodePort'}")
	if [[ -z "$BROKER_PORT" ]]; then
		echo "-- Failed to get the cns service $svc_name's external port."
		return 1
	fi
	return 0
}

##
## main
##

REPO_ROOT="$(realpath $(dirname $0))"
STARTUP_SCRIPT="${REPO_ROOT}/do-startup.sh"
RETRY_MAX=5
source ${REPO_ROOT}/lib/config.sh
source ${REPO_ROOT}/lib/util.sh

__pretty_print "" "Gluster-Kubernetes" "/"
__print_config

parse_args $@ || exit 1
if [ $DO_CONFIG_REVIEW = 0 ]; then
	read -rsn 1 -p "Please take a moment to review the configuration. Press any key to continue..."
	printf "\n\n"
fi

printf "\nThis script deploys a kubernetes cluster with $GK_NUM_NODES nodes and prepares them for testing gluster-kubernetes and object storage.\n"

verify_gcloud		|| exit 1
delete_templates	|| exit 1
create_network		|| exit 1
create_template		|| exit 1
create_group		|| exit 1
create_master		|| exit 1
master_minions_ips	|| exit 1
delete_rhgs_disks	|| exit 1
create_attach_disks	|| exit 1
wait_on_master		|| exit 1
if [ $INIT_KUBE = 0 ]; then
	join_minions		|| exit 1
	update_etc_hosts	|| exit 1
	if [ $INSTALL_GLUSTER = 0 ]; then
		create_topology || exit 1
		run_gk_deploy	|| exit 1
		if [ $INSTALL_OBJECT = 0 ]; then
			expose_gluster_s3	|| exit 1
			install_cns-broker	|| exit 1
		fi
	fi
fi

printf "\n-- Cluster Deployed!\n"
printf "   To ssh:\n"
printf "        gcloud compute ssh --zone=$GCP_ZONE $GK_MASTER_NAME\n\n"
if [ $INSTALL_GLUSTER = 0 ] && [ $INSTALL_OBJECT = 0 ]; then
	printf "   To deploy the service-catalog broker use:\n"
	printf "        CNS-Broker URL: http://%s\n\n" ${MASTER_IPS[1]}:$BROKER_PORT
fi
# end...
