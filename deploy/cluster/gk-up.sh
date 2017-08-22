#! /bin/bash

#debug 
set -x

set -e
set -u

REPO_ROOT="$(realpath $(dirname '${BASH_SOUCE[0]}')/../..)"
STARTUP_SCRIPT="${REPO_ROOT}/deploy/vm/do-startup.sh"
source "$REPO_ROOT/deploy/cluster/lib/gk-config.sh" 

echo "-- Gluster-Kubernetes --"
echo \
"This script will deploy a $GK_NUM_NODES node kubernetes cluster with dependencies for
testing gluster-kubernetes and object storage."
# Start Up Script
# Create Instance Template
GK_TEMPLATE="${GCP_USER}-gluster-kubernetes"
${GCLOUD} compute instance-templates create "$GK_TEMPLATE" \
	--image=$CLUSTER_OS_IMAGE --image-project=$CLUSTER_OS_IMAGE_PROJECT	\
	--machine-type=$MACHINE_TYPE --network=$GCP_NETWORK \
	--subnet=$GCP_NETWORK --region=$GCP_REGION  \
	--boot-disk-auto-delete --boot-disk-size=$NODE_BOOT_DISK_SIZE \
	--boot-disk-type=$NODE_BOOT_DISK_TYPE --metadata-from-file="startup-script"=$STARTUP_SCRIPT
# Create node Instance Group
GK_GROUP="$GCP_USER-gk-node" 
${GCLOUD} compute instance-groups managed create $GK_GROUP \
	--template=$GK_TEMPLATE --size=$GK_NUM_NODES --zone=$GCP_ZONE
GK_NODE_ARR=($(gcloud compute instance-groups managed list-instances $GK_GROUP | awk 'NR>1{print $1}')) 
#Create GFS Block Devices
BLK_PREFIX="$GCP_USER-gfs-block"
for (( i=0; i < ${#GK_NODE_ARR[@]}; i++ )); do
	GFS_BLK_ARR[$i]="$BLK_PREFIX-$i"
done
gcloud compute disks create "${GFS_BLK_ARR[@]}" --size=$GLUSTER_DISK_SIZE --zone=$GCP_ZONE

# Attach GFS Block Devices
for (( i=0; i < ${#GFS_BLK_ARR[@]}; i++ )); do
	gcloud compute instances attach-disk ${GK_NODE_ARR[$i]} --disk=${GFS_BLK_ARR[$i]} --zone=$GCP_ZONE
done
# Create master Instance
GK_MASTER="$GCP_USER-gk-master"
${GCLOUD} compute instances create $GK_MASTER --boot-disk-auto-delete \
	--boot-disk-size=$NODE_BOOT_DISK_SIZE --boot-disk-type=$NODE_BOOT_DISK_TYPE \
	--image-project=$CLUSTER_OS_IMAGE_PROJECT --machine-type=$MASTER_MACHINE_TYPE \
	--network=$GCP_NETWORK --zone=$GCP_ZONE --image=$CLUSTER_OS_IMAGE \
	--metadata-from-file="startup-script"=$STARTUP_SCRIPT
#TODO add cleanup on fail for better idempotency
#TODO Poll VMs for status RUNNING
#TODO Poll via SSH kubelet for Ready
#TODO Poll master for kube node READY
#TODO Get via ssh kube master IP, kubeadm token
#TODO Do via ssh kube join from nodes
#TODO Once all nodes READY/RUNNING, do gk-deploy
