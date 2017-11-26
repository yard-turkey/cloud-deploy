#! /bin/bash
#
# 'init.sh' is expected to be sourced. This file include functions for initializing the
# environment based on the cloud provider. GCE and AWS are the only providers supported
# for now. All functions must be prefixed with "init::".
#

# init::load_provider: source the utility file based on the passed-in provider.
# Returns 1 for errors.
function init::load_provider() {
	local provider="$1"
	if [[ -z "$provider" ]]; then
		echo "Missing required cloud-provider value" >&2
		return 1
	fi
	provider="$(tr '[:upper:]' '[:lower:]' <<<"$provider")"
	case $provider in
		aws|gce) ;;
		*) echo "Provider must be either aws or gce" >&2; return 1 ;;
	esac

	# source util functions based on provider
	local root="$(dirname '${BASH_SOURCE}')"
	if [[ ! -d "$root/$provider" ]]; then
		echo "Missing $provider directory under $root" >&2
		return 1
	fi
	local util="$root/$provider/util.sh"
	if [[ ! -f "$util" ]]; then
		echo "Missing $util" >&2
		return 1
	fi
	source $util || return 1
	return 0
}
