#! /bin/bash
# This script is copied to a GCE template and executed right after a node boots.
# The main reason to separate this script from gk-up.sh (and potentially other "up"
# scripts) is to improve bring up performance by reducing ssh calls.
#
# Assumptions:
# 1) the os image is rhel/centos based, meaning systemctl and selinux exist.
###
ROOT=/root
LOG_FILE=${ROOT}/start-script.log
SUCCESS_FILE=${ROOT}/__SUCCESS
KUBE_JOIN_FILE=/tmp/kube_join
NEXT_STEPS_FILE=${ROOT}/next_steps
set -eo pipefail

if [ $(id -u) != 0  ]; then
	echo "!!! Switching to root  !!!"
	sudo su
fi

exec 3>&1 4>&2
trap 'exec 1>&3 2>&4' 0 1 2 3
exec 1>${LOG_FILE} 2>&1

echo "============================================="
echo "               Start-Up Script"
echo "============================================="
echo "-- Changing to $ROOT dir"
cd $ROOT
echo "-- Stopping Firewall"
systemctl stop firewalld && systemctl disable firewalld
echo "-- Disabling SELinux"
setenforce 0

echo "-- Configuring SSH"
sed -i 's#PermitRootLogin no#PermitRootLogin without-password#' /etc/ssh/sshd_config
systemctl restart sshd

# Updating yum certs
yum -y upgrade ca-certificates --disablerepo=epel 

# Docker
echo "-- Installing Docker"
yum install docker-1.13.1 -y -q -e 0

echo "-- Starting Docker"
systemctl enable docker
systemctl start docker

# Gluster-Fuse
echo "-- Installing gluster-fuse"
yum install glusterfs-fuse -y -q -e 0

# Kubectl
echo "-- Installing kubectl"
curl -sSLO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
chmod +x ./kubectl
mv ./kubectl /usr/bin/

# Kubeadm
echo "-- Installing kubeadm, kubelet"
su -c "cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF"
yum install kubelet kubeadm -y -q -e 0

echo "-- Enabling kubelet"
systemctl enable kubelet
echo "-- Starting kubelet"
systemctl start kubelet

# Initialize the master node 
if [[ $(hostname -s) = *"master"* ]]; then
	echo "-- Looks like this is the master node. Doing extra initialization."
	echo "-- Setting up kube completion"
	mkdir -p .kube/
	kubectl completion bash > .kube/completion

	cat <<EOF >>/root/.bashrc
source /root/.kube/completion
alias kc=kubectl
EOF
	# Reload bash_profile
	source .bash_profile
	# QoL Setup
	echo "-- Yum installing bash-completion, tmux, unzip"
	yum install bash-completion tmux unzip -y -q -e 0
	echo "-- Pulling in custom tmux.conf"
	curl -sSLO https://raw.githubusercontent.com/copejon/sandbox/master/.tmux.conf

	# git
	echo "-- Installing git"
	yum install git -y -q -e 0

	# download cns-object-broker 
	echo "-- Installing cns-object-broker repo"
	git clone https://github.com/copejon/cns-object-broker.git
	
	# Gluster-Kubernetes
	echo "-- Getting gluster-kubernetes (s3 and block)"
	#curl -sSL https://github.com/copejon/gluster-kubernetes/archive/block-and-s3-sed-fix.tar.gz | tar -xz
	curl -sSL https://github.com/gluster/gluster-kubernetes/archive/master.tar.gz | tar -xzv

	# s3Curl
	echo "-- Installing s3curl"
	curl -sSLO http://s3.amazonaws.com/doc/s3-example-code/s3-curl.zip
	unzip -o s3-curl.zip
	mv s3-curl.zip /tmp/
	chmod 770 s3-curl/*.pl
	yum install perl-Digest-HMAC -y -q -e 0

	# helm
	echo "-- Installing helm"
	curl -sSL https://storage.googleapis.com/kubernetes-helm/helm-v2.5.0-linux-amd64.tar.gz | tar zx -C /tmp/
	mv $(find /tmp/ -name helm) /usr/bin/
	chmod +x /usr/bin/helm
	rm -rf /tmp/linux-amd64

	# socat
	echo "-- Installing socat"
	yum install socat -y -q -e 0

	# heketi-cli
	echo "-- Installing heketi-client"
	curl -sSL https://github.com/heketi/heketi/releases/download/v4.0.0/heketi-client-v4.0.0.linux.amd64.tar.gz | tar -xz -C /tmp/
	mv $(find /tmp/ -name heketi-cli) /usr/bin/
	chmod +x /usr/bin/heketi-cli

	printf "=== Setup Is almost complete! ==\n=== Do the following steps in order.\n" > $NEXT_STEPS_FILE

	# Kubeadm init
	echo "-- Initializing via kubeadm..."
	kubeadm init --pod-network-cidr=10.244.0.0/16 --skip-preflight-checks | tee >(sed -n '/kubeadm join --token/p' >> $KUBE_JOIN_FILE)
	KUBE_JOIN_CMD=$(cat $KUBE_JOIN_FILE)
	mkdir -p $ROOT/.kube
	sudo cp -f /etc/kubernetes/admin.conf $ROOT/.kube/config
	sudo chown $(id -u):$(id -g) $ROOT/.kube/config
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/k8s-manifests/kube-flannel-rbac.yml
	
	echo "Cordoning master kubelet"
	kubectl cordon $(kubectl get nodes | grep 'master' | awk '{print $1}')

	echo "Adding kube-system cluster role binding"
	kubectl create clusterrolebinding --clusterrole=cluster-admin --serviceaccount=kube-system:default cluster-addon

	echo "Deploying helm"
	helm init

	# write next (manual) steps to next_steps file
	cat <<EOF >>$NEXT_STEPS_FILE

Perfom the following manual steps on the master node:

  # For any additional kubernetes nodes, run (from node):
  $KUBE_JOIN_CMD

  # find gluster-s3 service endpoint
  kubectl get svc gluster-s3-service  #(cluster-ip:port)
  # modify s3-curl/s3curl.pl script: my @endpoints = ( '<above-IP (no-port)>', )

  # create bucket1
  s3-curl/s3curl.pl --debug --id 'user:user' --key 'user' --put /dev/null -- -k -v http://gluster-s3-svc-ip:8080/bucket1
  # create local file: stuff.txt with content...
  echo "stuff" > stuff.txt
  # create object from local file
  s3-curl/s3curl.pl --debug --id 'user:user' --key 'user' --put stuff.txt -- -k -v http://gluster-s3-svc-ip:8080/bucket1/stuff
  # get object bucket1/stuff
  s3-curl/s3curl.pl --debug --id 'user:user' --key 'user' -- -k -v -o mystuff.txt http://gluster-s3-svc-ip:8080/bucket1/stuff
EOF
fi
echo "Start up complete! See the $NEXT_STEPS_FILE for setting up kubernetes and deploying gluster."
touch $SUCCESS_FILE
