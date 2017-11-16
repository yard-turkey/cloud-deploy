#! /bin/bash
#
# 'aws-node-fix.sh' repairs a cluster when 1 or more aws nodes stop (usually for no apparent reason).
# Fixes the following:
#   - restarts the stopped aws node(s) and captures the new ip addresses.
#   - updates /etc/hosts on every node in the cluster with the new ips.
#   - waits for 'gluster peer status' to see the new ips
#   - remounts the gluster volume on the previously stopped aws nodes.
#
# Usage:
#	aws-node-fix.sh <instance-filter>
# Args:
#	value for --filter= arg in the aws and gce clis.
# Example:
#	aws-node-fix.sh jcope
# Assumptions:
#	- stopped nodes are aws nodes.
#

# Returns a list of gce dns names suitable for ssh.
# Sets GCE_NAMES.
function get_gce_names() {
	local filter="*$1*"

	GCE_NAMES="$(gcloud compute instances list --filter="$filter" --format='value(name)')"
	if (( $? != 0 )); then
		echo "error: failed to get list of gce node names"
		return 1
	fi
	if [[ -z "$GCE_NAMES" ]]; then
		echo "error: list of gce node names is empty"
		return 1
	fi
	# replace \n with space between names
	GCE_NAMES="$(tr '\n', ' ' <<<"$GCE_NAMES")"
	return 0
}

# Returns the following aws ec2 info by setting a global var for each:
# - aws-instance-id
# - aws-dns-node name,
# - aws-public-ip
function get_aws_info() {
	local filter="Name=tag:Name,Values='*$1*'"
	local query='Reservations[*].Instances[*].[InstanceId,PublicDnsName,PublicIpAddress]'
	local out

	out="$(aws ec2 --output text describe-instances --filter $filter --query $query)"
	if (( $? != 0 )); then
		echo "error: failed to get aws ec2 instance info"
		return 1
	fi
	if [[ -z "$out" ]]; then
		echo "error: aws ec2 instance info is empty"
		return 1
	fi
	# parse info and set global vars, format: "instance-id dns-name external-ip"
	while IFS= read -r rec; do
		AWS_IDS+="$(awk '{print $1}' <<<"$rec") "
		AWS_NAMES+="$(awk '{print $2}' <<<"$rec") "
		AWS_ORIG_IPS+="$(awk '{print $3}' <<<"$rec") "
	done <<<"$out"
	if [[ -z "$AWS_IDS" || -z "$AWS_NAMES" || -z "$AWS_ORIG_IPS" ]]; then
		echo -e "error: incomplete aws info:\nAWS_IDS=$AWS_IDS, AWS_NAMES=$AWS_NAMES, AWS_ORIG_IPS=$AWS_ORIG_IPS"
		return 1
	fi
	return 0
}

# Start aws ec2 instances based on ids passed in $1.
function start_aws_instances() {
	local ids "$1"

	aws ec2 start-instances --instance-id "$ids"
	if (( $? != 0 )); then
		echo "error: failed to start aws instances: $ids "
		return 1
	fi
	if [[ -z "$out" ]]; then
		echo "error: aws ec2 instance info is empty"
		return 1
	fi
	# parse info and set global vars, format: "instance-id dns-name external-ip"
	return 0
}

# Return a list of aws ec2 external ip addresses.
# Note: despite doc to the contrary, a list of ids cannot be passed to the aws ec2 cmd below.
function get_aws_ips() {
	local ids="$1"
	local query='Reservations[*].Instances[*].[PublicIpAddress]'
	local out; local rtn=''

	for id in $ids; do
		out="$(aws ec2 --output text describe-instances --instance-ids $id --query $query)"
		if (( $? != 0 )); then
			echo "error: failed to get aws ec2 instance's external ips for id $id"
			return 1
		fi
		if [[ -z "$out" ]]; then
			echo "error: aws ec2 instance's public ip is empty for id $id"
			return 1
		fi
		rtn+="$out "
	done

	echo "$rtn" # function return
	return 0
}

# Return the gluster volume name.
function get_vol_name() {
	local vol

	vol="$(gluster volume status | grep "Status of volume:")"
	if (( $? != 0 )); then
		echo "error: 'gluster vol status' failed"
		return 1
	fi
	if [[ -z "$vol" ]]; then
		echo "error: 'gluster vol status' output is empty"
		return 1
	fi
	echo "${vol#*: }" # function return, just vol name
	return 0
}

# Replace the original ec2 instance ip address with the new ip in /etc/hosts on all of the nodes.
# References global instance names vars.
function update_etc_hosts() {
update_etc_hosts() {
	local i; local node; local ip; local cmd
	local new_ips=($AWS_NEW_IPS) # convert to array

	# gce nodes
	for node in $GCE_NAMES; do
		i=0
		cmd=''
		for ip in $AWS_ORIG_IPS; do
			cmd+="-e 's/$ip/${new_ips[$i]}' "
			((i++))
		done
		cmd="sed -i $cmd /etc/hosts"
		gcloud compute ssh $node --command="$cmd" --zone=xxx
		if (( $? != 0 )); then
			echo "'gcloud compute ssh $node --command=$cmd' error"
			return 1
		fi
	done

	# ec2 nodes
	for node in $AWS_NAMES; do
		i=0
		cmd=''
		for ip in $AWS_ORIG_IPS; do
			cmd+="-e 's/$ip/${new_ips[$i]}' "
			((i++))
		done
		cmd="sed -i $cmd /etc/hosts"
		ssh centos:$node "$cmd"
		if (( $? != 0 )); then
			echo "'ssh centos:$node $cmd' error"
			return 1
		fi
	done
	return 0
}


## main ##

FILTER="$1"
if [[ -z "$FILTER" ]]; then
	echo "Missing required filter value, eg \"jcope\""
	exit 1
fi

# get gce nodes
GCE_VM_NAMES="$(get_gce_names $FILTER)" || exit 1

# get aws ids, dns names and original IPs (as global vars)
# TODO: can I get this info if the node is stopped??
AWS_IDS=''; AWS_NAMES=''; AWS_ORIG_IPS=''
get_aws_info $FILTER || exit 1

# start aws node(s)
start_aws_instances $AWS_IDS || exit 1

# get new aws node ips
AWS_NEW_IPS="$(get_aws_ips $AWS_IDS)"

# get the gluster volume name (expect only one)
GLUSTER_VOL="$(get_vol_name)" || exit 1

# update /etc/hosts on all nodes
update_etc_hosts || exit 1

# wait for peer status to see new ips
gluster_wait $GCE_NAMES || exit 1

# remount gluster volume on aws nodes
mount_vol $GLUSTER_VOL $AWS_NAMES || exit 1

exit 0

## misc notes:
# Note: can't seem to ssh to aws nodes via ip, need to use dns name...
