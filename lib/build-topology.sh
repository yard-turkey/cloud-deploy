#! /bin/bash

echo "-- Generate a GK-Deploy topology.json."
echo "This script will output the json formated string to stdout"
echo "It is designed to be standalone version of the algorithm"
echo "used in gk-up.sh"

source ./gk-config.sh

HOSTS=($(gcloud compute instances list --regexp=$GK_NODE_NAME.* | awk 'NR>1{ printf "%-30s%s\n", $1, $4}'))
printf "\n"
HEKETI_NODE_TEMPLATE=$( cat <<EOF
        {
          "node": {
            "hostnames": {
              "manage": [
                "NODE_NAME"
              ],
              "storage": [
                "NODE_IP"
              ]
            },
            "zone": 1
          },
          "devices": [
            "/dev/sdb"
          ]
        } 
EOF
)
GCE_NODES=""
INTERVAL=2
for (( i=0; i < ${#HOSTS[@]}; i+=INTERVAL )); do
	dtr=","
	if (( i == ${#HOSTS[@]} - INTERVAL )); then
		dtr=""
	fi
	NODE_NAME="${HOSTS[$i]}"
	NODE_IP="${HOSTS[$i+1]}"
	GFS_NODES=$(printf "%s\n%s%s" "$GFS_NODES" "$(sed -e "s/NODE_NAME/$NODE_NAME/" -e "s/NODE_IP/$NODE_IP/" <<<"$HEKETI_NODE_TEMPLATE")" "$dtr") 
done
TOPOLOGY=$( cat <<EOF
{
  "clusters": [
    {
      "nodes": [
        $GFS_NODES 
      ]
    }
  ]
} 
EOF
)
echo "$TOPOLOGY" 
