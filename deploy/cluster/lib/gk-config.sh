#! /bin/bash

# Prerequisite Utilities
GCLOUD=gcloud
CURL=curl

if ! $GCLOUD --version; then
   	echo "gcloud is not in \$PATH, cannot proceed." && exit 1
fi
if !$CURL --version; then
   	echo "curl is not in \$PATH, cannot proceed." && exit 1
fi

# Config
GCP_USER=${GCP_USER:-"$($GCLOUD config get-value account 2>/dev/null | sed 's#@.*##')"}
GK_NUM_NODES=${GK_NUM_NODES:-3}
MASTER_NAME=${MASTER_NAME:-"$GCP_USER-gk-master"}
NODE_NAME=${NODE_NAME:-"$GCP_USER-gk-node"}
GCP_REGION=${GCP_REGION:-$(gcloud config get-value compute/region 2>/dev/null)}
GCP_ZONE=${GCP_ZONE:-"$($GCLOUD config get-value compute/zone 2>/dev/null)"}
GCP_PROJECT=${PROJECT:-"$($GCLOUD config get-value project)"}
CLUSTER_OS_IMAGE_PROJECT=${CLUSTER_OS_IMAGE_PROJECT:-"rhel-cloud"}
CLUSTER_OS_IMAGE=${CLUSTER_OS_IMAGE:-"rhel-7-v20170816"}
GCP_NETWORK=${GCP_NETWORK:-"gluster-kubernetes"}  # TODO create network using $USER-gluster-kubernetes as name.
# MACHINE_TYPEs
MACHINE_TYPE=${MACHINE_TYPE:-"n1-standard-1"}
MASTER_MACHINE_TYPE=${MASTER_MACHINE_TYPE:-$MACHINE_TYPE}
NODE_MACHINE_TYPE=${NODE_MACHINE_TYPE:-$MACHINE_TYPE}
# DISK_TYPEs
BOOT_DISK_TYPE=${BOOT_DISK_TYPE:-"pd-standard"}
MASTER_BOOT_DISK_TYPE=${MASTER_BOOT_DISK_TYPE:-$BOOT_DISK_TYPE}
NODE_BOOT_DISK_TYPE=${NODE_BOOT_DISK_TYPE:-$BOOT_DISK_TYPE}
# DISK_SIZEs
BOOT_DISK_SIZE=${BOOT_DISK_SIZE:-"20GB"}
MASTER_BOOT_DISK_SIZE=${MASTER_BOOT_DISK_SIZE:-$BOOT_DISK_SIZE}
NODE_BOOT_DISK_SIZE=${NODE_BOOT_DISK_SIZE:-$BOOT_DISK_SIZE}
GLUSTER_DISK_SIZE=${NODE_GLUSTER_DISK_SIZE:-$BOOT_DISK_SIZE}
