#! /bin/bash

#TODO add cleanup on fail for better idempotency
#TODO Poll VMs for status RUNNING
#TODO Poll via SSH kubelet for Ready
#TODO Poll master for kube node READY
#TODO Get via ssh kube master IP, kubeadm token
#TODO Do via ssh kube join from nodes
#TODO Once all nodes READY/RUNNING, do gk-deploy

#set -x #debug
set -u

REPO_ROOT="$(realpath $(dirname $0)/../../)"
STARTUP_SCRIPT="${REPO_ROOT}/deploy/vm/do-startup.sh"
source $REPO_ROOT/deploy/cluster/lib/gk-config.sh
source $REPO_ROOT/deploy/cluster/lib/gk-util.sh

# Setting the state in case we decide to parse more opts in the future.
OVERRIDE_CLEANUP=false
while getopts y opt; do
	case "$opt" in
		y) OVERRIDE_CLEANUP=true ;;
		*) exit 1
	esac
done


echo "-- Gluster-Kubernetes --"
echo \
"This script will deploy a $GK_NUM_NODES node kubernetes cluster with dependencies for
testing gluster-kubernetes and object storage."

echo "Verifying binary dependencies."
util::check-binaries

echo "Checking for orphaned resources with '$GCP_USER' prefix."
util::check-orphaned-resources $GCP_USER
if [[ $? == 1 ]]; then
	if $OVERRIDE_CLEANUP; then
		util::do-cleanup
	else
		printf "Resources matching prefix '$GCP_USER' were discovered. Setup cannot continue until they are destroyed.\n\n"
		printf "[y] Cleanup resources and continue\n[N] Abort (default)\n"
		while :; do
			read -p "Destroy existing cluster resources? [y|N]: " do_cleanup
			case "$do_cleanup" in
				y|Y)
					echo "Destroying orphaned resources."
					util::do-cleanup
					break
					;;
				n|N|"")
					echo "Aborting cluster setup."
					exit 1
					break
					;;
				*)
					echo "Illegal option. Please select [y|Y] or [n|N]."
					;;

			esac
		done
	fi
fi

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
${GCLOUD} compute disks create "${GFS_BLK_ARR[@]}" --size=$GLUSTER_DISK_SIZE --zone=$GCP_ZONE

# Attach GFS Block Devices
for (( i=0; i < ${#GFS_BLK_ARR[@]}; i++ )); do
	${GCLOUD} compute instances attach-disk ${GK_NODE_ARR[$i]} --disk=${GFS_BLK_ARR[$i]} --zone=$GCP_ZONE
	${GCLOUD} compute instances set-disk-auto-delete ${GK_NODE_ARR[$i]} --disk=${GFS_BLK_ARR[$i]} --zone=$GCP_ZONE
done
# Create master Instance
GK_MASTER="$GCP_USER-gk-master"
${GCLOUD} compute instances create $GK_MASTER --boot-disk-auto-delete \
	--boot-disk-size=$NODE_BOOT_DISK_SIZE --boot-disk-type=$NODE_BOOT_DISK_TYPE \
	--image-project=$CLUSTER_OS_IMAGE_PROJECT --machine-type=$MASTER_MACHINE_TYPE \
	--network=$GCP_NETWORK --zone=$GCP_ZONE --image=$CLUSTER_OS_IMAGE \
	--metadata-from-file="startup-script"=$STARTUP_SCRIPT
