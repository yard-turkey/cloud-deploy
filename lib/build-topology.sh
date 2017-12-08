#! /bin/bash

echo "-- Generate a GK-Deploy topology.json."
echo "This script will output the json formated string to stdout"
echo "It is designed to be standalone version of the algorithm"
echo "used in gk-up.sh"

set -euo pipefail

REPO_ROOT="$(realpath $(dirname ../../))"
source "$REPO_ROOT"/lib/config.sh
source "$REPO_ROOT"/lib/util.sh

HOSTS=($(gcloud compute instances list --regexp="$GK_NODE_NAME.*" | awk 'NR>1{ printf "%-30s%s\n", $4, $1}'))
TOPO_PATH="$(util::gen_gk_topology \"${HOSTS[*]}\")"
printf "Successfully generated a new topology file: %s\n" "$TOPO_PATH"
