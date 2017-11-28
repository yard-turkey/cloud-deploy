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

# TODO add provider flag
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
		i)	# do not initialize anything.  allow the start up script to run then exit
			INIT_KUBE=1
			;&
		g)	# bare cluster:  do not install gluster; fallthrough and do not install object.
			INSTALL_GLUSTER=1
			;&
		s)	# only gluster: do not install object frontend
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

# Waiting for startup script to complete.
# Note: we wait longer for the master and nodes to be ready.
function wait_on_master() {
	echo "-- Waiting for start up scripts to complete on $GK_MASTER_NAME."
	util::exec_with_retry "gcloud compute ssh  $GK_MASTER_NAME --zone=$GCP_ZONE \
		--command='ls /root/__SUCCESS 2>/dev/null'" 50
}

# Wait for the minion node startup script to complete and attach kube minions to master.
function join_minions() {
	echo "-- Attaching minions to kube master."
	local token="$(gcloud compute ssh $GK_MASTER_NAME --zone=$GCP_ZONE --command='kubeadm token list' | \
		awk 'NR>1{print $1}')"
	local join_cmd="kubeadm join --skip-preflight-checks --token $token ${MASTER_IPS[0]}:6443" # internal ip
	for node in "${MINION_NAMES[@]}"; do
		echo "-- Waiting for start up scripts to complete on node $node."
		util::exec_with_retry "gcloud compute ssh --zone=$GCP_ZONE $node \
			--command='ls /root/__SUCCESS 2>/dev/null'" 50 \
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
	gcloud compute ssh "$GK_MASTER_NAME" --zone="$GCP_ZONE" \
		--command="printf '%s  %s  # Added by gk-up\n' ${HOSTS[*]} >>/etc/hosts"
}

# Build gluster-Kubernetes topology file.
function create_topology() {
	echo "-- Generating gluster-kubernetes topology.json"
	local topology_path="$(util::gen_gk_topology ${HOSTS[*]})"
	echo "-- Sending topology to $GK_MASTER_NAME:/tmp/"
	util::exec_with_retry "gcloud compute scp --zone=$GCP_ZONE $topology_path root@$GK_MASTER_NAME:/tmp/" $RETRY_MAX \
	|| return 1
	echo "-- Finding gk-deploy.sh on $GK_MASTER_NAME"
	GK_DEPLOY="$(gcloud compute ssh $GK_MASTER_NAME --zone=$GCP_ZONE \
		--command='find /root/ -type f -wholename *deploy/gk-deploy')"
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
        --command="$GK_DEPLOY -gvy --no-block ${s3_opts} /tmp/topology.json"
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
		--command='kubectl expose deployment gluster-s3-deployment --type=NodePort \
		  --port=8080'" $RETRY_MAX
}

# Install CNS Broker.
function install_cns-broker() {
	local svc_name="broker-cns-object-broker-node-port"
	local ns="broker"
	local chart="cns-object-broker/chart"
	echo "-- Deploying CNS Object Broker"
	util::exec_with_retry "gcloud compute ssh $GK_MASTER_NAME --zone=$GCP_ZONE \
		--command='helm install $chart --name broker --namespace $ns'" \
		$RETRY_MAX \
	|| return 1
	BROKER_PORT=$(gcloud compute ssh $GK_MASTER_NAME \
		--command="kubectl get svc -n $ns $svc_name \
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
#source ${REPO_ROOT}/lib/util.sh

__pretty_print "" "Gluster-Kubernetes" "/"
__print_config

parse_args $@ || exit 1
if [ $DO_CONFIG_REVIEW = 0 ]; then
	read -rsn 1 -p "Please take a moment to review the configuration. Press any key to continue..."
	printf "\n\n"
fi

printf "\nThis script deploys a kubernetes cluster with $GK_NUM_NODES nodes and prepares them for testing gluster-kubernetes and object storage.\n"

util::verify_gcloud		|| exit 1
exit 0
#gce_util::delete_templates	|| exit 1
#gce_util::create_network	|| exit 1
#gce_util::create_template	|| exit 1
#gce_util::create_group		|| exit 1
#gce_util::create_master		|| exit 1
#gce_util::master_minions_ips	|| exit 1
#gce_util::delete_rhgs_disks	|| exit 1
#gce_util::create_attach_disks	|| exit 1
wait_on_master			|| exit 1
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
