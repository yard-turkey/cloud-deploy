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

# check-binaries executes each binary with --version to check that it is
# actually available.
# args: none
# return
#	1 if binary --version fails
#	0 if binary --version succeeds
function util::check-binaries {
	local ret=0
	if ! $GCLOUD --version; then
		echo "$GCLOUD is not reachable from \$PATH"
		ret=1
	fi
	if ! $CURL --version; then
		echo "$CURL is not reacable from \$PATH"
		ret=1
	fi
	return $ret
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
	local instances=$($GCLOUD compute instances list --regexp="$GCP_USER".* 2>/dev/null)
	local instgroups=$($GCLOUD compute instance-groups list --regexp="$GCP_USER".* 2>/dev/null)
	local templates=$($GCLOUD compute instance-templates list --regexp="$GCP_USER".* 2>/dev/null)
	local disks=$($GCLOUD compute disks list --regexp="$GCP_USER".* 2>/dev/null)
	ret=0	
	if [[ -n "$instances" ]]; then
		ret=1
		printf "\n========Found Instances========\n%s\n" "$instances"
		INSTANCES_LIST=$(echo "$instances" | awk 'NR>1{print $1}')
	fi
	if [[ -n "$instgroups" ]]; then
		ret=1
		printf "\n========Found Instance Groups========\n%s\n" "$instgroups"
		GROUPS_LIST=$(echo "$instgroups" | awk 'NR>1{print $1}')
	fi
	if [[ -n "$templates" ]]; then
		ret=1
		printf "\n========Found Instance Templates========\n%s\n" "$templates"
		TEMPLATES_LIST=$(echo "$templates" | awk 'NR>1{print $1}')
	fi
	if [[ -n "$disks" ]]; then
		ret=1
		printf "\n========Found Disks========\n%s\n" "$disks"
		DISKS_LIST=$(echo "$disks" | awk 'NR>1{print $1}')
	fi
	return $ret
}

function util::do-cleanup {
	if [[ -n "${GROUPS_LIST:-}"  ]]; then
		if ! $GCLOUD compute instance-groups managed delete "${GROUPS_LIST:-}" --quiet ; then
			echo "Failed to clean up all instance groups. Remaining:"
			$GCLOUD compute instance-groups managed list --regexp="$GCP_USER".*
		fi
	fi
	if [[ -n "${INSTANCES_LIST:-}" ]]; then
		if ! $GCLOUD compute instances delete ${INSTANCES_LIST:-} --quiet ; then
			echo "Failed to clean up all instances. Remaining:"
			$GCLOUD compute instances list --regexp="$GCP_USER".*
		fi
	fi
	if [[ -n "${TEMPLATES_LIST:-}" ]]; then
		if ! $GCLOUD compute instance-templates delete "${TEMPLATES_LIST:-}" --quiet ; then
			echo "Failed to clean up all instances. Remaining:"
			$GCLOUD compute instance-templates list --regexp="$GCP_USER".*
		fi
	fi
	if [[ -n "${DISKS_LIST:-}" ]]; then
		if ! $GCLOUD compute disks delete  "${DISKS_LIST:-}" --quiet ; then
			echo "Failed to clean up all instances. Remaining:"
			$GCLOUD compute disks list --regexp="$GCP_USER".*
		fi
	fi
}
