#! /bin/bash

# Config
GCP_USER=${GCP_USER:-"$(gcloud config get-value account 2>/dev/null | sed 's#@.*##')"}
GK_NUM_NODES=${GK_NUM_NODES:-3}
GK_MASTER_NAME=${MASTER_NAME:-"$GCP_USER-gk-master"}
GK_NODE_NAME="$GCP_USER-gk-node"
GCP_REGION=${GCP_REGION:-$(gcloud config get-value compute/region 2>/dev/null)}
GCP_ZONE=${GCP_ZONE:-"$(gcloud config get-value compute/zone 2>/dev/null)"}
GCP_PROJECT=${PROJECT:-"$(gcloud config get-value project)"}
CLUSTER_OS_IMAGE_PROJECT=${CLUSTER_OS_IMAGE_PROJECT:-"rhel-cloud"}
CLUSTER_OS_IMAGE=${CLUSTER_OS_IMAGE:-"rhel-7-v20170816"}
GCP_NETWORK=${GCP_NETWORK:-"$GCP_USER-gluster-kubernetes"}  # TODO create network using $USER-gluster-kubernetes as name.
# HARDWARE PRESETS
MACHINE_TYPE=${MACHINE_TYPE:-"n1-standard-1"}
BOOT_DISK_TYPE=${BOOT_DISK_TYPE:-"pd-standard"}
BOOT_DISK_SIZE=${BOOT_DISK_SIZE:-"20GB"}
## MACHINE_TYPEs
MASTER_MACHINE_TYPE=${MASTER_MACHINE_TYPE:-$MACHINE_TYPE}
NODE_MACHINE_TYPE=${NODE_MACHINE_TYPE:-$MACHINE_TYPE}
## DISK_TYPEs
MASTER_BOOT_DISK_TYPE=${MASTER_BOOT_DISK_TYPE:-$BOOT_DISK_TYPE}
NODE_BOOT_DISK_TYPE=${NODE_BOOT_DISK_TYPE:-$BOOT_DISK_TYPE}
## DISK_SIZEs
MASTER_BOOT_DISK_SIZE=${MASTER_BOOT_DISK_SIZE:-$BOOT_DISK_SIZE}
NODE_BOOT_DISK_SIZE=${NODE_BOOT_DISK_SIZE:-$BOOT_DISK_SIZE}
GLUSTER_DISK_SIZE=${NODE_GLUSTER_DISK_SIZE:-$BOOT_DISK_SIZE}

function __pretty_print {
	local key="${1:-}"
	local val="${2:-}"
	local padchar="${3:-.}"
	local table_width=50
	local max_width=80
	local fill=$(printf "%s" $(for ((i=0; i<max_width; ++i)); do printf "$padchar"; done )) 
	printf "%s%*.*s%s\n" "$key" 0 $(( $table_width - ${#key} - ${#val} )) "$fill" "$val"
}

function __print_config {
	__pretty_print "CLUSTER CONFIGURATION" "" "/"
	__pretty_print "GCP_USER"					"$GCP_USER"
	__pretty_print "GK_NUM_NODES"				"$GK_NUM_NODES"
	__pretty_print "GK_MASTER_NAME"				"$GK_MASTER_NAME"
	__pretty_print "GCP_REGION"					"$GCP_REGION"
	__pretty_print "GCP_ZONE"					"$GCP_ZONE"
	__pretty_print "GCP_NETWORK"				"$GCP_NETWORK"
	__pretty_print "GCP_PROJECT"				"$GCP_PROJECT"
	__pretty_print "CLUSTER_OS_IMAGE_PROJECT"	"$CLUSTER_OS_IMAGE_PROJECT"
	__pretty_print "CLUSTER_OS_IMAGE"			"$CLUSTER_OS_IMAGE"
	printf "\n"
	__pretty_print "HARDWARE PRESETS" 
	__pretty_print "MACHINE_TYPE"				"$MACHINE_TYPE"
	__pretty_print "BOOT_DISK_TYPE"				"$BOOT_DISK_TYPE"
	__pretty_print "BOOT_DISK_SIZE"				"$BOOT_DISK_SIZE"

	printf "\n"
	__pretty_print "MACHINE_TYPE(s)"
	__pretty_print "MASTER_MACHINE_TYPE"		"$MASTER_MACHINE_TYPE"
	__pretty_print "NODE_MACHINE_TYPE"			"$NODE_MACHINE_TYPE"

	printf "\n"
	__pretty_print "DISK_TYPE(s)"
	__pretty_print "MASTER_BOOT_DISK_TYPE"		"$MASTER_BOOT_DISK_TYPE"
	__pretty_print "NODE_BOOT_DISK_TYPE"		"$NODE_BOOT_DISK_TYPE"

	printf "\n"
	__pretty_print "DISK_SIZE(s)"
	__pretty_print "MASTER_BOOT_DISK_SIZE"		"$MASTER_BOOT_DISK_SIZE"
	__pretty_print "NODE_BOOT_DISK_SIZE"		"$NODE_BOOT_DISK_SIZE"
	__pretty_print "GLUSTER_DISK_SIZE"			"$GLUSTER_DISK_SIZE"
	__pretty_print "" "" "\\"
	printf "\n"
}
