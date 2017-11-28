# TODO generify this function to take a set of IPs
# Set the internal and external ip arrays for the master node and all minions.
# Sets: MASTER_IPS, MINION_NAMES, MINION_IPS, and HOSTS global vars.
# Note: the MINION_IPS map is not yet referenced but remains for future usage.
function gce_util::master_minions_ips() {
	echo "-- Setting global master and minion internal and external ip addresses."
	# format: (internal-ip external-ip)
	MASTER_IPS=($(gcloud compute instances list --filter="zone:($GCP_ZONE) name:($GK_MASTER_NAME)" \
		--format="value(networkInterfaces[0].networkIP,\
		  networkInterfaces[0].accessConfigs[0].natIP)"))
	if (( ${#MASTER_IPS[@]} == 0 )); then
		echo "Failed to get master node $GK_MASTER_NAME's ip addresses."
		return 1
	fi

	# Make a single call to gcloud to get all minion info
	# format: (hostname internal-ip external-ip...)
	local minions=($(gcloud compute instances list --filter="zone:($GCP_ZONE) name:($GK_NODE_NAME)" \
		--format="value(name,networkInterfaces[0].networkIP,\
		  networkInterfaces[0].accessConfigs[0].natIP)"))
	if (( ${#minions[@]} == 0 )); then
		echo "Failed to get minions."
		return 1
	fi

	# set MINION_NAMES and HOSTS arrays, and MINION_IPS map
	declare -A MINION_IPS=() # key=hostname, value="internal-ip external-ip"
	HOSTS=() # format: (internal-ip minion-name internal-ip minion-name...)
	MINION_NAMES=() # format: (name name..)
	size=${#minions[@]}
	for ((i=0; i<=$size-3; i+=3 )); do
		host="${minions[$i]}"
		int_ip=${minions[$i+1]} # internal ip
		ext_ip=${minions[$i+2]} # external ip
		MINION_IPS[$host]="$int_ip $ext_ip"
		MINION_NAMES+=($host)
		HOSTS+=($int_ip $host)
	done
	return 0
}
