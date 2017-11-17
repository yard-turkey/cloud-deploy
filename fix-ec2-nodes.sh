#! /bin/bash
#
# 'fix-ec2-nodes.sh' repairs a cluster when 1 or more ec2 nodes have stopped (usually for no
# apparent reason).
# Fixes the following:
#   - restarts the stopped ec2 node(s) and captures their new ip addresses.
#   - updates /etc/hosts on every node in the cluster with the new ips.
#   - waits for 'gluster peer status' to see the new ips
#   - remounts the gluster volume on the previously stopped aws nodes.
#
# Usage:
#	fix-ec2-nodes.sh <instance-filter>
# Args:
#	same value used as '--filter=' in the aws and gce cli.
# Example:
#	fix-ex2-nodes.sh jcope
# Assumptions:
#	- stopped nodes are aws ec2 nodes.
#

# Sets globals GCE_NAMES and GCE_ZONES such that 'gcloud compute ssh' works.
function get_gce_info() {
	local filter="$1"
	local info

	echo "*** collecting gce instance info based on filter=$filter..."
	info="$(gcloud compute instances list --filter="$filter" --format='value(name,zone)')"
	if (( $? != 0 )); then
		echo "error: failed to get list of gce node names"
		return 1
	fi
	if [[ -z "$info" ]]; then
		echo "error: list of gce node names is empty"
		return 1
	fi
	# parse info and set global vars, format: "instance-name zone"
	local rec
	while IFS= read -r rec; do
		GCE_NAMES+="$(awk '{print $1}' <<<"$rec") "
		GCE_ZONES+="$(awk '{print $2}' <<<"$rec") "
	done <<<"$info"
	echo "*** success"; echo
	return 0
}

# Sets globals for the following aws ec2 info:
# - aws-instance-id
# - aws-node-name.
function get_aws_info() {
	local filter="Name=tag:Name,Values='*$1*'"
	local query='Reservations[*].Instances[*].[InstanceId,PublicDnsName,PublicIpAddress]'

	echo "*** collecting ec2 instance info based on filter=$filter..."
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
	local rec
	while IFS= read -r rec; do
		AWS_IDS+="$(awk '{print $1}' <<<"$rec") "
		AWS_NAMES+="$(awk '{print $2}' <<<"$rec") "
	done <<<"$out"
	if [[ -z "$AWS_IDS" || -z "$AWS_NAMES" ]]; then
		echo -e "error: incomplete aws info:\nAWS_IDS=$AWS_IDS, AWS_NAMES=$AWS_NAMES"
		return 1
	fi
	echo "*** success"; echo
	return 0
}

# Start aws ec2 instances based on passed-in ids.
function start_aws_instances() {
	local ids="$@"
	local id; local errcnt=0

	echo "*** starting ec2 instances based on ids: $ids..."
	for id in $ids; do
		aws ec2 start-instances --instance-id $id
		if (( $? != 0 )); then
			echo "error: failed to start ec2 instance $id"
			((errcnt++))
		fi
	done
	(( errcnt > 0 )) && return 1
	echo "*** success"; echo
	return 0
}

# Set a global var to a list of aws ec2 external ip addresses.
# Note: despite doc to the contrary, a list of ids cannot be passed to the aws ec2 cmd below.
function get_ec2_ips() {
	local ids="$@"
	local query='Reservations[*].Instances[*].[PublicIpAddress]'

	echo "*** getting new ips for ec2 instances based on ids: $ids..."
	local id; local ip
	for id in $ids; do
		ip="$(aws ec2 --output text describe-instances --instance-ids $id --query $query)"
		if (( $? != 0 )); then
			echo "error: failed to get ec2 instance's external ips for id $id"
			return 1
		fi
		if [[ -z "$ip" ]]; then
			echo "error: ec2 instance's public ip is empty for id $id"
			return 1
		fi
		AWS_NEW_IPS+="$ip "
	done
	echo "*** success"; echo
	return 0
}

# Set global GLUSTER_VOL to the gluster volume name by ssh'ing into the passed-in gce node.
# Note: use 'gluster vol info' since 'vol status' sometimes hangs when nodes are up and down
#   frequently.
# Assumptions:
# - there is only 1 gluster volume.
# Args: 1=target gce node, 2=target zone
function get_vol_name() {
	local node="$1"; local zone="$2"
	local cmd="gluster volume info | head -n2 | tail -n1"

	echo "*** getting the gluster volume name..."
	local vol="$(gcloud compute ssh $node --command="$cmd" --zone=$zone)"
	if (( $? != 0 )); then
		echo "error: '$cmd' failed"
		return 1
	fi
	if [[ -z "$vol" ]]; then
		echo "error: 'gluster vol info' output is empty"
		return 1
	fi
	GLUSTER_VOL="${vol#*: }"
	echo "*** success"; echo
	return 0
}

# Sets a global map keyed by an aws ec2 alias name found in /etc/hosts whose value is its new
# ip address (passed-in as arg @).
# References global vars.
function map_ec2_aliases() {
	local new_ips=($@)
	local ec2_host_alias='aws-node'
	local cmd="grep $ec2_host_alias /etc/hosts"

	echo "*** mapping aws ec2 /etc/hosts aliases to their new ips..."
	# get complete list of aws aliases by ssh'ing to a gce instance and fetching them from
	# that node's /etc/hosts file
	local matches=() # (ip-1 alias-1 ip-2 alias-2...)
	matches=($(gcloud compute ssh $GCE_NODE --command="$cmd" --zone=$GCE_ZONE))
	if (( $? != 0 )); then
		echo "'gcloud compute ssh $GCE_NODE --command=$cmd' error"
		return 1
	fi
	# delete ips, just want alias names
	local aliases=(); local i
	for ((i=1; i<${#matches[@]}; i+=2 )); do # start at 1 and skip one each loop
		aliases+=(${matches[$i]})
	done
	local num_aliases=${#aliases[@]}
	if (( num_aliases == 0 )); then
		echo "error: no aws alias matching $ec2_host_alias found in /etc/hosts on $GCE_NODE"
		return 1
	fi
	if (( num_aliases != ${#new_ips[@]} )); then
		echo "error: num of aws aliases in /etc/hosts ($num_aliases) != num of new ips (${#new_ips[@]})"
		return 1
	fi
	# create alias map
	local key; local ip
	for ((i=0; i<${#aliases[@]}; i++)); do
		ip=${new_ips[$i]}
		key=${aliases[$i]}
		AWS_ALIASES[$key]=$ip
	done
	echo "*** success"; echo
	return 0
}

# Asserts that various global arrays are of the expected and consistent sizes.
function sanity_check() {

	echo "*** internal sanity check on gce and aws variables..."
	# gce arrays:
	local arr1=($GCE_NAMES); local size1=${#arr1[@]}
	local arr2=($GCE_ZONES); local size2=${#arr2[@]}
	if (( size1 == 0 )); then
		echo "error: must have at least 1 gce instance"
		return 1
	fi
	if (( size1 != size2 )); then
		echo "error: expect num of gce instances ($size1) to = num of gce zones ($size2)"
		echo "    gce-names: ${GCE_NAMES[@]}"
		echo "    gce-zones: ${GCE_ZONES[@]}"
		return 1
	fi

	# aws arrays:
	arr1=($AWS_NAMES); size1=${#arr1[@]}
	arr2=($AWS_IDS); size2=${#arr2[@]}
	local arr3=($AWS_NEW_IPS); local size3=${#arr3[@]}
	local size4=${#AWS_ALIASES[@]}
	if (( size1 == 0 )); then
		echo "error: must have at least 1 aws ec2 instance"
		return 1
	fi
	if (( !(size1 == size2 && size2 == size3 && size3 == size4) )); then
		echo "error: expect num of aws instances ($size1), num of aws ids ($size2), num of aws ips ($size3), and num aws /etc/hosts aliases ($size4) to be the same"
		echo "    aws-names  : ${AWS_NAMES[@]}"
		echo "    aws-ids    : ${AWS_IDS[@]}"
		echo "    aws-ips    : ${AWS_NEW_IPS[@]}"
		echo "    aws-aliases: ${!AWS_ALIASES[@]}"
		return 1
	fi
	echo "*** success"; echo
	return 0
}

# Updates /etc/hosts aws entries with the new ec2 ips. Done on all of the nodes.
# References global vars.
# Assumptions:
# - the /etc/hosts ec2 entries are aliased as "aws-node1", "aws-node2", etc. This alias is not
#   captured by any aws ec2 attribute AFAIK. The most important thing is to be consistent across
#   all nodes by using the same ip with the same host alias.
function update_etc_hosts() {
	local zones=($GCE_ZONES) # convert to array
	local ec2_host_alias='aws-node'

	# construct sed cmd to update /etc/hosts on gce and aws instances
	local cmd=''; local alias
	for alias in ${!AWS_ALIASES[@]}; do
		cmd+="-e '/$alias/s/^.* /${AWS_ALIASES[$alias]} /' " # alias's new ip
	done
	cmd="sudo sed -i $cmd /etc/hosts"

	echo "*** updating /etc/hosts on gce instances..."
	local i=0; local node; local zone
	for node in $GCE_NAMES; do
		zone="${zones[$i]}"
		gcloud compute ssh $node --command="$cmd" --zone=$zone
		if (( $? != 0 )); then
			echo "'gcloud compute ssh $node --command=$cmd' error"
			return 1
		fi
		((i++))
	done

	echo "*** updating /etc/hosts on ec2 instances..."
	# note: even though $cmd contains all aws aliases and the aws hosts file should contain
	#  one less than all of the aliases, the sed command does not fail when a '-e alias' name
	# is not found in /etc/hosts
	for node in $AWS_NAMES; do
		ssh $AWS_SSH_USER@$node "$cmd"
		if (( $? != 0 )); then
			echo "'ssh $AWS_SSH_USER@$node $cmd' error"
			return 1
		fi
	done
	echo "*** success"; echo
	return 0
}

# Waits for 'gluster peer status' to not display "(Disconnected)" for any of the nodes.
# "Disconnected" indicates that a node is not responsive.
# Args: 1=gce node to ssh into, 2=gce zone
function gluster_wait() {
	local node="$1"; local zone="$2"
	local maxTries=5
	local cmd="for (( i=0; i<$maxTries; i++ )); do cnt=\$(gluster peer status|grep -c '(Disconnected)'); (( cnt == 0 )) && break; sleep 3; done; (( i < $maxTries )) && exit 0 || exit 1"

	echo "*** waiting for gluster to reconnect to ec2 nodes..."
	gcloud compute ssh $node --command="$cmd" --zone=$zone
	if (( $? != 0 )); then
		echo "'gluster peer status' not showing all nodes connected after $maxTries tries"
		return 1
	fi
	echo "*** success"; echo
	return 0
}

# Mounts the passed-in gluster volume on the aws ec2 nodes.
# Assumptions:
# - mount path is hard-coded to "/mnt/vol".
function mount_vol() {
	local vol="$1"
	local mntPath='/mnt/vol'

	echo "*** remounting gluster volume \"$vol\" on ec2 instances..."
	local node; local cmd; local errcnt=0; local err
	for node in $AWS_NAMES; do
		cmd="sudo mount -t glusterfs $node:/$vol $mntPath"
		ssh $AWS_SSH_USER@$node "$cmd"
		err=$?
		if (( err != 0 && err != 32 )); then # 32==already mounted which is ok
			echo "'ssh $AWS_SSH_USER@$node $cmd' error"
			((errcnt++))
		fi
	done
	(( errcnt > 0 )) && return 1
	echo "*** success"; echo
	return 0
}


## main ##

cat <<END

   This script attempts to repair AWS EC2 instances which have been stopped. These
   instances are restarted, /etc/hosts on all nodes in the cluster is updated to
   reflect the new ips for the started AWS instances, and the gluster volume is 
   remounted on the AWS nodes.

   Usage: $0 <simple-filter-string>  eg. $0 jcope

END

FILTER="$1"
if [[ -z "$FILTER" ]]; then
	echo "Missing required filter value"
	exit 1
fi
sleep 3

AWS_SSH_USER='centos'

# get gce instance names (as a global var)
GCE_NAMES=''; GCE_ZONES=''
get_gce_info $FILTER || exit 1
GCE_NODE="$(cut -f1 -d' ' <<<"$GCE_NAMES")"
GCE_ZONE="$(cut -f1 -d' ' <<<"$GCE_ZONES")"

# get aws ids, dns names and original IPs (as global vars)
# TODO: can I get this info if the node is stopped??
AWS_IDS=''; AWS_NAMES=''
get_aws_info $FILTER || exit 1

# start ec2 nodes
start_aws_instances $AWS_IDS || exit 1

# get new ec2 instance ips (as a global var)
AWS_NEW_IPS=''
get_ec2_ips $AWS_IDS

# get the gluster volume name (as global var). Expect only one volume.
GLUSTER_VOL=''
get_vol_name $GCE_NODE $GCE_ZONE || exit 1

# map /etc/hosts aliases for the ec2 nodes to their new ips (as a global map)
declare -A AWS_ALIASES=()
map_ec2_aliases $AWS_NEW_IPS || exit 1

# make sure the variables defined so far are sane
sanity_check || exit 1

# update /etc/hosts on all nodes
update_etc_hosts || exit 1

# wait for peer status to see new ips
gluster_wait $GCE_NODE $GCE_ZONE $AWS_NEW_IPS || exit 1

# remount gluster volume on aws nodes
mount_vol $GLUSTER_VOL || exit 1

exit 0
