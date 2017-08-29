#! /bin/bash

#TODO add cleanup on fail for better idempotency
#TODO Poll VMs for status RUNNING
#TODO Poll via SSH kubelet for Ready
#TODO Poll master for kube node READY
#TODO Get via ssh kube master IP, kubeadm token
#TODO Do via ssh kube join from nodes
#TODO Once all nodes READY/RUNNING, do gk-deploy

set -euo pipefail

REPO_ROOT="$(realpath $(dirname $0)/../../)"
STARTUP_SCRIPT="${REPO_ROOT}/deploy/vm/do-startup.sh"
source $REPO_ROOT/deploy/cluster/lib/gk-config.sh
echo "-- Gluster-Kubernetes --"
echo \
"This script will deploy a kubernetes cluster with $GK_NUM_NODES nodes and prepare them for
testing gluster-kubernetes and object storage."
echo "-- Verifying gcloud."
if ! gcloud --version &> /dev/null; then
	echo "-- Failed to execute gcloud --version."
	exit 1
fi
# Cleanup old templates
GK_TEMPLATE="${GCP_USER}-gluster-kubernetes"
GK_GROUP="${GCP_USER}-gk-node"
echo "-- Looking for old templates."
if gcloud compute instance-templates describe $GK_TEMPLATE &>/dev/null; then
	echo "-- Instance template $GK_TEMPLATE already exists. Checking for dependent instance groups."
	# Cleanup old groups.  Templates cannot be deleted until they have no dependent groups..
	if gcloud compute instance-groups managed describe $GK_GROUP --zone=$GCP_ZONE &>/dev/null; then
		echo "-- Instance group $GK_GROUP already exists, deleting before proceeding."
		if ! gcloud compute instance-groups managed delete $GK_GROUP --zone=$GCP_ZONE --quiet; then
			echo "-- Failed to delete instance group $GK_GROUP."
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
attempt=0
readonly attempt_max=5
# Create new template
echo "-- Creating instance template: $GK_TEMPLATE."
while : ; do
	echo "-- Attempt $attempt to create instance template $GK_TEMPLATE.  Max retries: $attempt_max"
	if gcloud compute instance-templates create "${GK_TEMPLATE}" \
	--image=$CLUSTER_OS_IMAGE --image-project=$CLUSTER_OS_IMAGE_PROJECT	\
	--machine-type=$MACHINE_TYPE --network=$GCP_NETWORK \
	--subnet=$GCP_NETWORK --region=$GCP_REGION  \
	--boot-disk-auto-delete --boot-disk-size=$NODE_BOOT_DISK_SIZE \
	--boot-disk-type=$NODE_BOOT_DISK_TYPE --metadata-from-file="startup-script"=$STARTUP_SCRIPT;
		then
			break
	else
		if (( attempt >= attempt_max )); then
			echo "-- Failed to create instance template after $attempt_max retries."
			exit 1
		fi
		echo "-- Failed to create instance template $GK_TEMPLATE, retrying."
		(( ++attempt ))
	fi
done
# Create new group
echo "-- Creating instance group: $GK_GROUP."
attempt=0
while : ; do
	echo "-- Attempt $attempt to create instance groups $GK_GROUP.  Max retries: $attempt_max"
	if gcloud compute instance-groups managed create $GK_GROUP --zone=$GCP_ZONE --template=$GK_TEMPLATE --size=$GK_NUM_NODES; then
		GK_NODE_ARR=($(gcloud compute instance-groups managed list-instances $GK_GROUP --zone=$GCP_ZONE | awk 'NR>1{print $1}'))
		break
	else
		if (( attempt >= attempt_max )); then
			echo "-- Failed to create instance group $GK_GROUP after $attempt_max retries."
			exit 1
		fi
		echo "-- Failed to create instance group $GK_GROUP, retrying."
		(( ++attempt ))
	fi
done
# Clean up old GFS disks
BLK_PREFIX="$GCP_USER-gfs-block"
for (( i=0; i < ${#GK_NODE_ARR[@]}; i++ )); do
	GFS_BLK_ARR[$i]="$BLK_PREFIX-$i"
done
echo "-- Looking for old GFS disks with prefix $BLK_PREFIX."
OLD_GFS_BLK_ARR=($(gcloud compute disks list --regexp='$BLK_PREFIX.*' 2>/dev/null | awk 'NR>1{print $1}'))
if (( ${#OLD_GFS_BLK_ARR[@]} > 0 )); then
	echo "-- Disk(s) ${OLD_GFS_BLK_ARR[@]} already exists. Deleting them before proceeding."
	if ! gcloud compute disks delete "${OLD_GFS_BLK_ARR[@]}" --zone=$GCP_ZONE --quiet; then
		echo "-- Failed to delete old GFS disk"
		exit 1
	fi
else
	echo "-- No pre-existing GFS block devices found."
fi
# Create GFS disks
echo "-- Creating GFS block devices: ${GFS_BLK_ARR[@]}"
attempt=0
while :; do
	echo "-- Attempt $attempt to create gfs disks ${GFS_BLK_ARR[@]}. Max retries: $attempt_max"
	if gcloud compute disks create "${GFS_BLK_ARR[@]}" --size=$GLUSTER_DISK_SIZE --zone=$GCP_ZONE; then
		break
	else
		if (( attempt >= attempt_max )); then
			echo "-- Failed to create gfs disk ${GFS_BLK_ARR[$i]} after $attempt_max retries."
			exit 1
		fi
		echo "-- Failed to create gfs disks. Retrying."
		(( ++attempt ))
	fi
done
# Attach GFS Block Devices to nodes
echo "-- Attaching GFS disks to nodes."
for (( i=0; i < ${#GFS_BLK_ARR[@]}; i++ )); do
	# Make several attach attempts per disk.
	attempt=0
	while :; do
		echo "-- Attempt $attempt to attach disk ${GFS_BLK_ARR[$i]} to ${GK_NODE_ARR[$i]}"
		if	gcloud compute instances attach-disk ${GK_NODE_ARR[$i]} --disk=${GFS_BLK_ARR[$i]} --zone=$GCP_ZONE && \
			gcloud compute instances set-disk-auto-delete ${GK_NODE_ARR[$i]} --disk=${GFS_BLK_ARR[$i]} --zone=$GCP_ZONE; then
			break
		else
			if (( attempt >= attempt_max )); then
				echo "-- Failed to attach disk ${GFS_BLK_ARR[$i]} to ${GK_NODE_ARR[$i]}"
				exit 1
			fi
			echo "-- Failed to attach disk ${GFS_BLK_ARR[$i]} to ${GK_NODE_ARR[$i]}.  Retrying"
		fi
	done
done
# Create master Instance
GK_MASTER="$GCP_USER-gk-master"
echo "-- Looking for old master instance: $GK_MASTER."
if gcloud compute instances describe $GK_MASTER --zone=$GCP_ZONE &>/dev/null; then
	echo "-- Instance $GK_MASTER  already exists. Deleting it before proceeding."
	if ! gcloud compute instances delete $GK_MASTER --zone=$GCP_ZONE --quiet; then
		echo "-- Failed to delete instance $GK_MASTER"
		exit 1
	fi
else
	echo "-- No pre-existing master instance found."
fi
echo "-- Creating master instance: $GK_MASTER"
attempt=0
while :; do
	if gcloud compute instances create $GK_MASTER --boot-disk-auto-delete \
		--boot-disk-size=$NODE_BOOT_DISK_SIZE --boot-disk-type=$NODE_BOOT_DISK_TYPE \
		--image-project=$CLUSTER_OS_IMAGE_PROJECT --machine-type=$MASTER_MACHINE_TYPE \
		--network=$GCP_NETWORK --zone=$GCP_ZONE --image=$CLUSTER_OS_IMAGE \
		--metadata-from-file="startup-script"=$STARTUP_SCRIPT; then
		break
	else
		if (( attempt >= attempt_max )); then
			echo "-- Failed to create instance $GK_MASTER after $attempt_max retries."
			exit 1
		fi
		(( ++attempt ))
	fi
done

# Update nodes' hosts file


