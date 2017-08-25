#! /bin/bash

# Prerequisite Utilities
GCLOUD=$(which gcloud)
CURL=$(which curl)
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
# PRESETS
MACHINE_TYPE=${MACHINE_TYPE:-"n1-standard-1"}
BOOT_DISK_TYPE=${BOOT_DISK_TYPE:-"pd-standard"}
BOOT_DISK_SIZE=${BOOT_DISK_SIZE:-"20GB"}
# MACHINE_TYPEs
MASTER_MACHINE_TYPE=${MASTER_MACHINE_TYPE:-$MACHINE_TYPE}
NODE_MACHINE_TYPE=${NODE_MACHINE_TYPE:-$MACHINE_TYPE}
# DISK_TYPEs
MASTER_BOOT_DISK_TYPE=${MASTER_BOOT_DISK_TYPE:-$BOOT_DISK_TYPE}
NODE_BOOT_DISK_TYPE=${NODE_BOOT_DISK_TYPE:-$BOOT_DISK_TYPE}
# DISK_SIZEs
MASTER_BOOT_DISK_SIZE=${MASTER_BOOT_DISK_SIZE:-$BOOT_DISK_SIZE}
NODE_BOOT_DISK_SIZE=${NODE_BOOT_DISK_SIZE:-$BOOT_DISK_SIZE}
GLUSTER_DISK_SIZE=${NODE_GLUSTER_DISK_SIZE:-$BOOT_DISK_SIZE}
