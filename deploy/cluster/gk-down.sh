#! /bin/bash

set -x 
REPO_ROOT="$(realpath $(dirname $0)/../../)"

source $REPO_ROOT/deploy/cluster/lib/gk-config.sh
source $REPO_ROOT/deploy/cluster/lib/gk-util.sh

util::check-orphaned-resources
util::do-cleanup
