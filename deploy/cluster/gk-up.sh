#! /bin/bash

#TODO Once all nodes READY/RUNNING, do gk-deploy

set -euo pipefail

REPO_ROOT="$(realpath $(dirname $0)/../../)"
STARTUP_SCRIPT="${REPO_ROOT}/deploy/vm/do-startup.sh"
RETRY_MAX=5
source $REPO_ROOT/deploy/cluster/lib/config.sh
source $REPO_ROOT/deploy/cluster/lib/util.sh

__pretty_print "" "Gluster-Kubernetes" "/"
__print_config

DO_CONFIG_REVIEW=true
while getopts yY o; do
	case "$o" in
		y|Y)
			DO_CONFIG_REVIEW=false
			;;
		[?])
			echo "Usage: -y or -Y to skip config review."
			;;
	esac
done

echo "This script will deploy a kubernetes cluster with $GK_NUM_NODES nodes and prepare them for 
testing gluster-kubernetes and object storage."
if $DO_CONFIG_REVIEW; then
	read -rsn 1 -p "Please take a moment to review the configuration. Press any key to continue..."
	printf "\n\n"	
fi

echo "-- Verifying gcloud."
if ! gcloud --version &> /dev/null; then
	echo "-- Failed to execute gcloud --version."
	exit 1
fi
# Cleanup old templates
GK_TEMPLATE="$GK_NODE_NAME"
echo "-- Looking for old templates."
if gcloud compute instance-templates describe $GK_TEMPLATE &>/dev/null; then
	echo "-- Instance template $GK_TEMPLATE already exists. Checking for dependent instance groups."
	# Cleanup old groups.  Templates cannot be deleted until they have no dependent groups..
	if gcloud compute instance-groups managed describe $GK_NODE_NAME --zone=$GCP_ZONE &>/dev/null; then
		echo "-- Instance group $GK_NODE_NAME already exists, deleting before proceeding."
		if ! gcloud compute instance-groups managed delete $GK_NODE_NAME --zone=$GCP_ZONE --quiet; then
			echo "-- Failed to delete instance group $GK_NODE_NAME."
			exit 1
		fi
	fi	
	echo "-- Deleting instance template $GK_TEMPLATE."
	if ! gcloud compute instance-templates delete $GK_TEMPLATE --quiet; then
		echo "-- Failed to delete instance-template $GK_TEMPLATE."
		exit 1
	fi
else
	echo "-- No pre-existing template found."
fi

# Create new template
echo "-- Creating instance template: $GK_TEMPLATE."
util::exec_with_retry "gcloud compute instance-templates create "${GK_TEMPLATE}" \
	--image=$CLUSTER_OS_IMAGE --image-project=$CLUSTER_OS_IMAGE_PROJECT \
	--machine-type=$MACHINE_TYPE --network=$GCP_NETWORK \
	--subnet=$GCP_NETWORK --region=$GCP_REGION  \
	--boot-disk-auto-delete --boot-disk-size=$NODE_BOOT_DISK_SIZE \
	--boot-disk-type=$NODE_BOOT_DISK_TYPE --metadata-from-file=\"startup-script\"=$STARTUP_SCRIPT" \
	$RETRY_MAX

# Create new group
echo "-- Creating instance group: $GK_NODE_NAME."
util::exec_with_retry "gcloud compute instance-groups managed create $GK_NODE_NAME --zone=$GCP_ZONE \
	--template=$GK_TEMPLATE --size=$GK_NUM_NODES" $RETRY_MAX

# Clean up old RHGS disks
GK_NODE_ARR=($(gcloud compute instance-groups managed list-instances $GK_NODE_NAME --zone=$GCP_ZONE | awk 'NR>1{print $1}' | tr '\n' ' '))
DISK_PREFIX="$GCP_USER-rhgs"
echo "-- Looking for old RHGS disks with prefix $DISK_PREFIX."
for (( i=0; i<${#GK_NODE_ARR[@]}; i++ )); do
	disk="$DISK_PREFIX-$i"
	OBJ_STORAGE_ARR[$i]=$disk
	if gcloud compute disks describe $disk &>/dev/null; then
		echo "Found disk $disk. Deleting."
		if ! gcloud compute disks delete $disk --zone=$GCP_ZONE --quiet; then
			echo "-- Failed to delete old RHGS disk"
			exit 1
		fi
	fi
done
# Create RHGS disks
echo "-- Creating RHGS block devices: ${OBJ_STORAGE_ARR[@]}"
util::exec_with_retry "gcloud compute disks create ${OBJ_STORAGE_ARR[*]} \
	--size=$GLUSTER_DISK_SIZE --zone=$GCP_ZONE" $RETRY_MAX

# Attach RHGS Block Devices to nodes
echo "-- Attaching RHGS disks to nodes."
for (( i=0; i < ${#OBJ_STORAGE_ARR[@]}; i++ )); do
	# Make several attach attempts per disk.
	util::exec_with_retry "gcloud compute instances attach-disk ${GK_NODE_ARR[$i]} \
		--disk=${OBJ_STORAGE_ARR[$i]} --zone=$GCP_ZONE" $RETRY_MAX
	util::exec_with_retry "gcloud compute instances set-disk-auto-delete ${GK_NODE_ARR[$i]} \
		--disk=${OBJ_STORAGE_ARR[$i]} --zone=$GCP_ZONE" $RETRY_MAX
done
# Create master Instance
echo "-- Looking for old master instance: $GK_MASTER_NAME."
if gcloud compute instances describe $GK_MASTER_NAME --zone=$GCP_ZONE &>/dev/null; then
	echo "-- Instance $GK_MASTER_NAME  already exists. Deleting it before proceeding."
	if ! gcloud compute instances delete $GK_MASTER_NAME --zone=$GCP_ZONE --quiet; then
		echo "-- Failed to delete instance $GK_MASTER_NAME"
		exit 1
	fi
else
	echo "-- No pre-existing master instance found."
fi
echo "-- Creating master instance: $GK_MASTER_NAME"
util::exec_with_retry "gcloud compute instances create $GK_MASTER_NAME --boot-disk-auto-delete \
	--boot-disk-size=$NODE_BOOT_DISK_SIZE --boot-disk-type=$NODE_BOOT_DISK_TYPE \
	--image-project=$CLUSTER_OS_IMAGE_PROJECT --machine-type=$MASTER_MACHINE_TYPE \
	--network=$GCP_NETWORK --zone=$GCP_ZONE --image=$CLUSTER_OS_IMAGE \
	--metadata-from-file=\"startup-script\"=$STARTUP_SCRIPT" $RETRY_MAX
# Update nodes' hosts file
echo "-- Updating hosts file on master."
HOSTS=($(gcloud compute instances list --filter=$GK_NODE_NAME \
	--format="value(name,networkInterfaces[0].networkIP)"))
	#note: HOSTS format is: (name ext-ip name ext-ip name ext-ip....) in pairs
util::exec_with_retry "gcloud compute ssh $GK_MASTER_NAME \
	--command='printf \"%s  %s\n\" ${HOSTS[*]} >>/etc/hosts'" $RETRY_MAX

# Waiting for startup script to complete.
echo "-- Waiting for start up scripts to complete on $GK_MASTER_NAME."
util::exec_with_retry "gcloud compute ssh $GK_MASTER_NAME \
	--command='ls /root/__SUCCESS 2>/dev/null'" 50
echo "-- Script complete!!"
# Attach kube minions to master.
echo "-- Attaching minions to kube master." 
token="$(gcloud compute ssh $GK_MASTER_NAME --command="kubeadm token list" | \
	awk 'NR>1{print $1}')"
master_internal_ip=$(gcloud compute instances list \
	--filter="zone:($GCP_ZONE) name=($GK_MASTER_NAME)" \
	--format="value(networkInterfaces[0].networkIP)")
join_cmd="kubeadm join --token $token $master_internal_ip:6443"
for node in "${GK_NODE_ARR[@]}"; do
	echo "-- Waiting for start up scripts to complete on node $node."
	util::exec_with_retry "gcloud compute ssh $node \
		--command='ls /root/__SUCCESS 2>/dev/null'" 50
	# Attach kubelet to master
	echo "-- Executing '$join_cmd' on node $node."
	util::exec_with_retry "gcloud compute ssh $node --command='${join_cmd}'" $RETRY_MAX
done
# Build Gluster-Kubernetes Topology File:
echo "-- Generating gluster-kubernetes topology.json"
TOPOLOGY_PATH="$(util::gen_gk_topology ${HOSTS[*]})"
# Deploy Gluster
echo "-- Sending topology to $GK_MASTER_NAME:/tmp/"
util::exec_with_retry "gcloud compute scp $TOPOLOGY_PATH root@$GK_MASTER_NAME:/tmp/" $RETRY_MAX
echo "-- Finding gk-deploy.sh on $GK_MASTER_NAME"
gk_deploy="$(gcloud compute ssh $GK_MASTER_NAME \
	--command='find /root/ -type f -wholename *deploy/gk-deploy')"
if (( $? != 0 )) || [[ -z "$gk_deploy" ]]; then
	echo "-- Failed to find gk-deploy cmd on master."
	exit 1
fi
echo "-- Running gk-deploy.sh on $GK_MASTER_NAME..."
echo "   $gk_deploy -gvy --no-block --object-account=$GCP_USER --object-user=$GCP_USER \
	 --object-password=$GCP_USER /tmp/topology.json"
gcloud compute ssh $GK_MASTER_NAME --command="$gk_deploy -gvy --no-block \
	--object-account=$GCP_USER --object-user=$GCP_USER --object-password=$GCP_USER \
	/tmp/topology.json"
if (( $? != 0 )); then
	echo "-- Failed to run $gk_deploy on master $GK_MASTER_NAME"
	exit 1
fi

# Expose gluster s3
util::exec_with_retry "gcloud compute ssh $GK_MASTER_NAME --zone=$GCP_ZONE \
	--command='kubectl expose deployment gluster-s3-deployment --type=NodePort --port=8080'" $RETRY_MAX
# Install CNS Broke
echo "-- Deploying CNS Object Broker"
util::exec_with_retry "gcloud compute ssh $GK_MASTER_NAME --zone=$GCP_ZONE \
	--command='helm install cns-object-broker/chart --name broker --namespace broker'" \
	$RETRY_MAX
BROKER_PORT=$(gcloud compute ssh $GK_MASTER_NAME \
	--command="kubectl get svc -n broker broker-cns-object-broker-node-port \
	  -o jsonpath={.'spec'.'ports'[0].'nodePort'}")
MASTER_IP=$(gcloud compute instances list --filter="zone:($GCP_ZONE) name:($GK_MASTER_NAME)" \
	--format="value(networkInterfaces[0].accessConfigs[0].natIP)")
echo "-- Cluster Deployed!"
printf "   To ssh:\n\n  gcloud compute ssh $GK_MASTER_NAME\n\n"
printf "   Deploy the service-catalog broker with:\n\n"
printf "     CNS-Broker URL: %s\n\n"  "http://$MASTER_IP:$BROKER_PORT"
