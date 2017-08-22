#! /bin/bash

# Copythis script into the start-up script box in the GCE instance creation ui.

SCRIPT="do-startup.sh"
cd /tmp/
curl -LO https://raw.githubusercontent.com/copejon/gk-cluster-deploy/master/deploy/vm/$SCRIPT
chmod +x $SCRIPT
. $SCROPT
