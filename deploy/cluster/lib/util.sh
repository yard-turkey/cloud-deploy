#! /bin/bash

# Generate a 4 character string to be used as a suffix for
# GCP resources.
# Returns: Array of stings.
# Args:
#	1 - int, number of unique suffixes required.
function util::unique_id_arr {
	local num_ids=${1:-"4"}
	UUIDS="$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n $num_ids)"
}

# pre-start-check looks for existing resources that may have been orphaned
# from a prior run.
# args:
#   prefix($1): expected name prefix (usually $GCP_USER)
# returns GLOBALS:
#	O_INSTANCES		list of instance names				e.g. "inst1 inst2 inst3"
#	O_GROUPS		list of instance group names		''			''	
#	O_TEMPLATES		list of	instance template names		''			''
#	O_DISKS			list of disk names					''			''
function util::check-orphaned-resources {
	local instances=$(gcloud compute instances list --regexp="$GCP_USER".* 2>/dev/null)
	local instgroups=$(gcloud compute instance-groups list --regexp="$GCP_USER".* 2>/dev/null)
	local templates=$(gcloud compute instance-templates list --regexp="$GCP_USER".* 2>/dev/null)
	local disks=$(gcloud compute disks list --regexp="$GCP_USER".* 2>/dev/null)
	if [[ -n "$instances" ]]; then
		printf "\n========Found Instances========\n%s\n" "$instances"
		INSTANCES_LIST=$(echo "$instances" | awk 'NR>1{print $1}')
	fi
	if [[ -n "$instgroups" ]]; then
		printf "\n========Found Instance Groups========\n%s\n" "$instgroups"
		GROUPS_LIST=$(echo "$instgroups" | awk 'NR>1{print $1}')
	fi
	if [[ -n "$templates" ]]; then
		printf "\n========Found Instance Templates========\n%s\n" "$templates"
		TEMPLATES_LIST=$(echo "$templates" | awk 'NR>1{print $1}')
	fi
	if [[ -n "$disks" ]]; then
		printf "\n========Found Disks========\n%s\n" "$disks"
		DISKS_LIST=$(echo "$disks" | awk 'NR>1{print $1}')
	fi
}

function util::do-cleanup {
	if [[ -n "${GROUPS_LIST:-}"  ]]; then
		if ! gcloud compute instance-groups managed delete "${GROUPS_LIST:-}" --quiet ; then
			echo "Failed to clean up all instance groups. Remaining:"
			gcloud compute instance-groups managed list --regexp="$GCP_USER".*
		fi
	fi
	if [[ -n "${INSTANCES_LIST:-}" ]]; then
		if ! gcloud compute instances delete ${INSTANCES_LIST:-} --quiet ; then
			echo "Failed to clean up all instances. Remaining:"
			gcloud compute instances list --regexp="$GCP_USER".*
		fi
	fi
	if [[ -n "${TEMPLATES_LIST:-}" ]]; then
		if ! gcloud compute instance-templates delete "${TEMPLATES_LIST:-}" --quiet ; then
			echo "Failed to clean up all instances. Remaining:"
			gcloud compute instance-templates list --regexp="$GCP_USER".*
		fi
	fi
	if [[ -n "${DISKS_LIST:-}" ]]; then
		if ! gcloud compute disks delete  "${DISKS_LIST:-}" --quiet ; then
			echo "Failed to clean up all instances. Remaining:"
			gcloud compute disks list --regexp="$GCP_USER".*
		fi
	fi
}

# Args:
#	$1) cmd to exec
#	$2) Max Retries
function util::exec_with_retry {
	local cmd="$1"
	local max_attempts=$2
	local attempt=0
	echo "-- $cmd (max attempts: $max_attempts)"
	until eval "$cmd"; do
		((attempt+=1))
		if (( attempt > max_attempts )); then
			echo "Command \"$cmd\" failed after $max_attempts attempts."
			return 1
		fi
		sleep 3
		echo "-- $attempt of $max_attempts: $cmd"
	done
	return 0
}

# util::gen_gk_topology
# Creates topology.json consumable by gk-deploy.sh
# Stores the file in $REPO_ROOT/.tmp-$RANDOM-$$
# Args:
#	$@= storage_nodes. A list of hostnames and ips, eg:
#	    host1  ip1  host2  ip2  host3  ip3 ...
# Return (echo) path to topology.json
function util::gen_gk_topology {
	local storage_nodes=($@)  # convert to array
	local heketi_node_template=$(cat <<EOF
        {
          "node": {
            "hostnames": {
              "manage": [
                "NODE_NAME"
              ],
              "storage": [
                "NODE_IP"
              ]
            },
            "zone": 1
          },
          "devices": [
            "/dev/sdb"
          ]
        } 
EOF
	)
	local gfs_nodes=""
	local hosts_size=${#HOSTS[@]}
	local dtr=","
	for (( i=0; i < hosts_size-1; i+=2 )); do
		(( i ==  hosts_size - 2 )) && dtr=""  # last pair
		local node_name="${HOSTS[$i]}"
		local node_ip="${HOSTS[$i+1]}"
		gfs_nodes=$(printf "%s\n%s%s" "$gfs_nodes" "$(sed -e "s/NODE_NAME/$node_name/" -e "s/NODE_IP/$node_ip/" <<<"$heketi_node_template")" "$dtr") 
	done
	local TEMP_DIR="$REPO_ROOT/.tmp-$RANDOM-$$"
	mkdir $TEMP_DIR
	local TOPOLOGY_FILE="$TEMP_DIR/topology.json"
	cat <<EOF >$TOPOLOGY_FILE
{
  "clusters": [
    {
      "nodes": [
        $gfs_nodes
      ]
    }
  ]
}
EOF
	echo "$TOPOLOGY_FILE"
}
