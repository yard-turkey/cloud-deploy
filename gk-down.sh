#! /bin/bash

set -euo pipefail
REPO_ROOT="$(realpath $(dirname $0)/../../)"

source $REPO_ROOT/deploy/cluster/lib/config.sh
source $REPO_ROOT/deploy/cluster/lib/util.sh

util::check-orphaned-resources
util::do-cleanup
