#! /bin/bash

source ./deploy/cluster/lib/gk-config.sh

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
#printf "$TOPOLOGY"
set -x
GCE_NODES=""
for (( i=0; i < ${#HOSTS[@]}; i+=2 )); do
	dtr=""
	if (( i * 2 < ${#HOSTS[@]} - 1 )); then
		dtr=","
	fi
	NODE_NAME="${HOSTS[$i]}"
	NODE_IP="${HOSTS[$i+1]}"
	GFS_NODES=$(printf "%s\n%s%s" "$GFS_NODES" "$(sed -e "s/NODE_NAME/$NODE_NAME/" -e "s/NODE_IP/$NODE_IP/" <<<"$HEKETI_NODE_TEMPLATE")" "$dtr") 
done
set +x
#printf "%s\n" "$GFS_NODES"

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
