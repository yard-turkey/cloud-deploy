#! /bin/bash
set -euo pipefail

REPO_ROOT="$(realpath $(dirname $0)/../../)"
REPO_LIB="$REPO_ROOT/deploy/cluster/lib"
STARTUP_SCRIPT="${REPO_ROOT}/deploy/vm/do-startup.sh"
source $REPO_ROOT/deploy/cluster/lib/config.sh
source $REPO_ROOT/deploy/cluster/lib/util.sh

__pretty_print "" "Gluster-Kubernetes" "/"
__print_config
RETRY_MAX=5

# Give the user a moment to confirm the configuration.
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
if $DO_CONFIG_REVIEW; then
	read -rsn 1 -p "Please take a moment to review the configuration. Press any key to continue..."
	printf "\n\n"
fi

echo \
"This script will deploy a kubernetes cluster with $GK_NUM_NODES nodes and prepare them for
testing gluster-kubernetes and object storage."
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
#attempt=1
# Create new template
echo "-- Creating instance template: $GK_TEMPLATE."
util::exec_with_retry "gcloud compute instance-templates create "${GK_TEMPLATE}" \
--image=$CLUSTER_OS_IMAGE --image-project=$CLUSTER_OS_IMAGE_PROJECT	\
--machine-type=$MACHINE_TYPE --network=$GCP_NETWORK \
--subnet=$GCP_NETWORK --region=$GCP_REGION  \
--boot-disk-auto-delete --boot-disk-size=$NODE_BOOT_DISK_SIZE \
--boot-disk-type=$NODE_BOOT_DISK_TYPE --metadata-from-file=\"startup-script\"=$STARTUP_SCRIPT" $RETRY_MAX
 
#while : ; do
#	echo "-- Attempt $attempt to create instance template $GK_TEMPLATE.  Max retries: $attempt_max"
#	if gcloud compute instance-templates create "${GK_TEMPLATE}" \
#	--image=$CLUSTER_OS_IMAGE --image-project=$CLUSTER_OS_IMAGE_PROJECT	\
#	--machine-type=$MACHINE_TYPE --network=$GCP_NETWORK \
#	--subnet=$GCP_NETWORK --region=$GCP_REGION  \
#	--boot-disk-auto-delete --boot-disk-size=$NODE_BOOT_DISK_SIZE \
#	--boot-disk-type=$NODE_BOOT_DISK_TYPE --metadata-from-file="startup-script"=$STARTUP_SCRIPT;
#		then
#			break
#	else
#		if (( attempt >= attempt_max )); then
#			echo "-- Failed to create instance template after $attempt_max retries."
#			exit 1
#		fi
#		echo "-- Failed to create instance template $GK_TEMPLATE, retrying."
#		(( ++attempt ))
#	fi
#done
# Create new group
echo "-- Creating instance group: $GK_NODE_NAME."
#attempt=1
util::exec_with_retry "gcloud compute instance-groups managed create $GK_NODE_NAME --zone=$GCP_ZONE --template=$GK_TEMPLATE --size=$GK_NUM_NODES" $RETRY_MAX
#while : ; do
#	echo "-- Attempt $attempt to create instance groups $GK_NODE_NAME.  Max retries: $attempt_max"
#	if gcloud compute instance-groups managed create $GK_NODE_NAME --zone=$GCP_ZONE --template=$GK_TEMPLATE --size=$GK_NUM_NODES; then
#		GK_NODE_ARR=($(gcloud compute instance-groups managed list-instances $GK_NODE_NAME --zone=$GCP_ZONE | awk 'NR>1{print $1}'))
#		break
#	else
#		if (( attempt >= attempt_max )); then
#			echo "-- Failed to create instance group $GK_NODE_NAME after $attempt_max retries."
#			exit 1
#		fi
#		echo "-- Failed to create instance group $GK_NODE_NAME, retrying."
#		(( ++attempt ))
#	fi
#done
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
#attempt=1
util::exec_with_retry "gcloud compute disks create ${OBJ_STORAGE_ARR[@]} --size=$GLUSTER_DISK_SIZE --zone=$GCP_ZONE" $RETRY_MAX
#while :; do
#	echo "-- Attempt $attempt to create rhgs disks ${RHGS_BLK_ARR[@]}. Max retries: $attempt_max"
#	if gcloud compute disks create "${RHGS_BLK_ARR[@]}" --size=$GLUSTER_DISK_SIZE --zone=$GCP_ZONE; then
#		break
#	else
#		if (( attempt >= attempt_max )); then
#			echo "-- Failed to create rhgs disks ${RHGS_BLK_ARR[@]} after $attempt_max retries."
#			exit 1
#		fi
#		echo "-- Failed to create rhgs disks. Retrying."
#		(( ++attempt ))
#	fi
#done
# Attach RHGS Block Devices to nodes
echo "-- Attaching RHGS disks to nodes."
for (( i=0; i < ${#OBJ_STORAGE_ARR[@]}; i++ )); do
	# Make several attach attempts per disk.
#	attempt=1
	util::exec_with_retry "gcloud compute instances attach-disk ${GK_NODE_ARR[$i]} --disk=${OBJ_STORAGE_ARR[$i]} --zone=$GCP_ZONE" $RETRY_MAX
	util::exec_with_retry "gcloud compute instances set-disk-auto-delete ${GK_NODE_ARR[$i]} --disk=${OBJ_STORAGE_ARR[$i]} --zone=$GCP_ZONE" $RETRY_MAX
#	while :; do
#		echo "-- Attempt $attempt to attach disk ${RHGS_BLK_ARR[$i]} to ${GK_NODE_ARR[$i]}"
#		if	$( gcloud compute instances attach-disk ${GK_NODE_ARR[$i]} --disk=${RHGS_BLK_ARR[$i]} --zone=$GCP_ZONE && \
#			gcloud compute instances set-disk-auto-delete ${GK_NODE_ARR[$i]} --disk=${RHGS_BLK_ARR[$i]} --zone=$GCP_ZONE); then
#			break
#		else
#			if (( attempt >= attempt_max )); then
#				echo "-- Failed to attach disk ${RHGS_BLK_ARR[$i]} to ${GK_NODE_ARR[$i]}"
#				exit 1
#			fi
#			echo "-- Failed to attach disk ${RHGS_BLK_ARR[$i]} to ${GK_NODE_ARR[$i]}.  Retrying"
#		fi
#	done
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
#attempt=1
#while :; do
#	if gcloud compute instances create $GK_MASTER_NAME --boot-disk-auto-delete \
#		--boot-disk-size=$NODE_BOOT_DISK_SIZE --boot-disk-type=$NODE_BOOT_DISK_TYPE \
#		--image-project=$CLUSTER_OS_IMAGE_PROJECT --machine-type=$MASTER_MACHINE_TYPE \
#		--network=$GCP_NETWORK --zone=$GCP_ZONE --image=$CLUSTER_OS_IMAGE \
#		--metadata-from-file="startup-script"=$STARTUP_SCRIPT; then
#		break
#	else
#		if (( attempt >= attempt_max )); then
#			echo "-- Failed to create instance $GK_MASTER_NAME after $attempt_max retries."
#			exit 1
#		fi
#		(( ++attempt ))
#	fi
#done
# Update nodes' hosts file
echo "-- Updating hosts file on master."
HOSTS=($(gcloud compute instances list --regexp=$GK_NODE_NAME.* | awk 'NR>1{ printf "%-30s%s\n", $1, $4}'))
util::exec_with_retry "gcloud compute ssh $GK_MASTER_NAME --command=\"echo \"${HOSTS[@]}\" >> /etc/hosts\"" $RETRY_MAX
#attempt=1
#while ! gcloud compute ssh $GK_MASTER_NAME --command="echo \"${HOSTS}\" >> /etc/hosts"; do
#	if (( attempt >= attempt_max )); then
#		echo  "-- Failed to update master's /etc/hosts file.  Do so manually with \`gcloud compute instances list --regexp=$GCP_USER.*\` to get internal IPs.\\r"
#	fi
#	echo -ne "-- Attempt $attempt to update /etc/hosts file failed.  Retrying.\\r"
#	(( ++attempt ))
#done

# Waiting for startup script to complete.
echo "-- Waiting for start up scripts to complete on $GK_MASTER_NAME."
util::exec_with_retry "gcloud compute ssh $GK_MASTER_NAME --command=\"cat /root/__SUCCESS &>/dev/null\""
#attempt=1
#while ! gcloud compute ssh $GK_MASTER_NAME --command="cat /root/__SUCCESS &>/dev/null"; do
#	echo -ne "-- Attempt $attempt to check /root/__SUCCESS file on $GK_MASTER_NAME.\\r"
#	if (( attempt > 100  )); then
#		echo "-- Timeout waiting for $GK_MASTER_NAME start script to complete."
#		echo "-- Latest log:"
#		gcloud compute ssh $GK_MASTER_NAME --command="cat /root/start-script.log"
#		exit 1
#	fi
#	(( ++attempt ))
#	sleep 1
#done
echo "-- Script complete!!"
# Attach kube minions to master.
echo "-- Attaching minions to kube master." 
#attempt=1
token=$(gcloud compute ssh $GK_MASTER_NAME --command="kubeadm token list" | awk 'NR>1{print $1}')
master_internal_ip=$(gcloud compute instances list $GK_MASTER_NAME | awk 'NR>1{print $4}')
join_cmd="kubeadm join --token $token $master_internal_ip:6443"
for node in "${GK_NODE_ARR[@]}"; do
	util::exec_with_retry "gcloud compute ssh $node --command=\"cat /root/__SUCCESS &>/dev/null"\" $RETRY_MAX
#	while ! gcloud compute ssh $node --command="cat /root/__SUCCESS &>/dev/null"; do
#		echo "-- Attempt $attempt. Waiting for node $node start script to finish.."
#		if (( attempt > 30 )); then
#			echo "-- Timeout waiting for start up on node $node."
#			exit 1
#		fi
#		(( ++attempt ))
#		sleep 1
#	done
	# Attach kubelet to master
	echo "-- Executing '$join_cmd' on node $node."
	util::exec_with_retry "gcloud compute ssh $node --command=\"${join_cmd}\""
done
# Build Gluster-Kubernetes Topology File:
echo "-- Generating gluster-kubernetes topology.json"
TOPOLOGY_PATH=util::gen_gk_topology "${HOSTS[@]}"
# Deploy Gluster
echo "-- Sending topology to $GK_MASTER_NAME:/tmp/"
util::exec_with_retry "gcloud compute scp $TOPOLOGY_PATH root@$GK_MASTER_NAME:/tmp/" $RETRY_MAX
#while : ; do
#	if gcloud compute scp --zone="$GCP_ZONE" $TOPOLOGY_FILE root@$GK_MASTER_NAME:/tmp/; then
#		break
#	else
#		if (( attempt >= RETRY_MAX )); then
#			echo "Failed to send topology file after $attempt attempts."
#			exit 1
#		fi
#	fi
#	(( ++attempt ))
#done
# Deploying Gluster-Kubernetes
echo "-- Running gk-deploy.sh on $GK_MASTER_NAME"
util::exec_with_retry "gcloud compute ssh $GK_MASTER_NAME --command=\"\$(find /root/ -type f -wholename \"*deploy/gk-deploy\") -gvy --no-block --object-account=$GCP_USER --object-user=$GCP_USER --object-password=$GCP_USER /tmp/topology.json\"" $RETRY_MAX
#attempt=0
#while : ; do 
#	if gcloud compute ssh $GK_MASTER_NAME --zone="$GCP_ZONE" --command="\$(find /root/ -type f -wholename "*deploy/gk-deploy") -gvy --no-block --object-account=$GCP_USER --object-user=$GCP_USER --object-password=$GCP_USER /tmp/topology.json"; then
#		break
#	else
#		if (( attempt >= RETRY_MAX )); then
#			echo "Failed to start gluster-kubernetes via SSH at $attempt attempts."
#			exit 1
#		fi
#	fi
#	(( ++attempt ))
#done
# Expose gluster s3
attempt=0
while : ; do
	if gcloud compute ssh $GK_MASTER_NAME --zone="$GCP_ZONE" --command="kubectl expose deployment gluster-s3-deployment --port=8080 --type=NodePort"; then
		break
	else
		if (( attempt >= RETRY_MAX )); then
			echo "-- Failed to expose gluster-s3-deployment after $attempt attempts."
			exit 1
		fi
	fi
	(( ++attempt ))
done
# Install CNS Broker
echo "-- Deploying CNS Object Broker"
attempt=0
while : ; do
	if gcloud compute ssh $GK_MASTER_NAME --zone="$GCP_ZONE" --command="helm install cns-object-broker/chart --name broker --namespace broker"; then
		break
	else
		if (( attempt >= RETRY_MAX )); then
			echo "Failed to deploy cns-object-broker after $attempt attempts."
			exit 1
		fi
	fi
done
BROKER_PORT=$(gcloud compute ssh $GK_MASTER_NAME --command="kubectl get svc -n broker broker-cns-object-broker-node-port -o jsonpath={.\"spec\".\"ports\"[0].\"nodePort\"}")
MASTER_IP=$(gcloud compute instances list --zones="$GCP_ZONE" --filter=jcope-gk-master | awk 'NR>1{print $5}')
echo "-- Cluster Deployed!"
printf "To ssh:\n\n  gcloud compute ssh $GK_MASTER_NAME\n\n"
printf "Deploy the service-catalog broker with:\n\n"
printf "    CNS-Broker URL: %s\n\n"  "http://$MASTER_IP:$BROKER_PORT"
