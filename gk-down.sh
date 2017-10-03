#! /bin/bash

set -euo pipefail
REPO_ROOT="$(realpath $(dirname $0))"

source $REPO_ROOT/lib/config.sh
source $REPO_ROOT/lib/util.sh

util::check-orphaned-resources
util::do-cleanup
