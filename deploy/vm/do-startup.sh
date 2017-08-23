#! /bin/bash


### TODOs
# parse gluster-s3-ep socket.

ROOT=/root
LOG_FILE=${ROOT}/start-script.log
SUCCESS_FILE=${ROOT}/__STARTUP_SUCCESS
NEXT_STEPS_FILE=${ROOT}/next_steps

set -exo pipefail

if [ $(id -u) != 0  ]; then
	echo "!!! Switching to root  !!!"
	sudo su
fi

echo "--cd-ing to $ROOT home"
cd $ROOT

touch $NEXT_STEPS_FILE

exec 3>&1 4>&2
trap $(exec 1>&3 2>&4) 0 1 2 3
exec 1>${LOG_FILE} 2>&1

echo "============================================="
echo "               Start-Up Script"
echo "============================================="

systemctl stop firewalld && systemctl disable firewalld
setenforce 0

echo "-- Configuring SSH"
echo "enabling ssh root login"
sed -i 's#PermitRootLogin no#PermitRootLogin yes#' /etc/ssh/sshd_config
systemctl restart sshd

# Docker
echo "-- Installing Docker"
yum install docker-1.12.6 -y -q -e 0
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
echo "-- Installing kubeadm"
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

# Start the kubelet on minions only
if ! [[ $(hostname -s) = *"master"* ]]; then
	systemctl enable kubelet
	systemctl start kubelet
fi


# Initialize the master node 
if [[ $(hostname -s) = *"master"* ]]; then
	echo "Looks like this is the master node. Initializing kubeadm"

	# QoL Setup
	yum install bash-completion tmux unzip -y -q -e 0
	curl -sSLO https://raw.githubusercontent.com/copejon/sandbox/master/.tmux.conf
	mkdir -p /root/.kube
	kubectl completion bash > /root/.kube/completion
	cat <<EOF >>/root/.bashrc
source /root/.kube/completion
alias kc=kubectl
export GOPATH=/root/go
export PATH=$PATH:/usr/local/bin
EOF

	# Gluster-Kubernetes
	echo "-- Installing gluster-kubernetes"
	curl -sSL https://github.com/gluster/gluster-kubernetes/archive/master.tar.gz | tar -xz
	curl -sSL https://github.com/jarrpa/gluster-kubernetes/archive/block-and-s3.tar.gz | tar -xz

	# s3Curl
	echo "-- Installing s3curl"
	curl -sSLO http://s3.amazonaws.com/doc/s3-example-code/s3-curl.zip
	unzip s3-curl.zip
	mv s3-curl.zip /tmp/
	chmod 770 s3-curl/*.pl
	yum install perl-Digest-HMAC -y -q -e 0

	# helm
	echo "-- Installing helm"
	curl -sSLO https://storage.googleapis.com/kubernetes-helm/helm-v2.5.0-linux-amd64.tar.gz
	tar -zxvf helm-v2.5.0-linux-amd64.tar.gz -C /tmp
	mv /tmp/linux-amd64/helm /usr/local/bin/

	# socat
	echo "-- Installing socat"
	yum install socat -y -q -e 0

	# golang
	echo "-- Installing golang"
	yum install golang -y -q -e 0

	# git
	echo "-- Installing git"
	yum install git -y -q -e 0

	# minio s3 client
	echo "-- Installing minio"
	go get -u github.com/minio/minio-go

	# heketi-client
	echo "-- Installing heketi-client"
	curl -sSL https://github.com/heketi/heketi/releases/download/v4.0.0/heketi-client-v4.0.0.linux.amd64.tar.gz | tar -xz
	mv $(find ./ -name heketi-cli) /usr/bin/

	# jon's service-catalog repo
	echo "-- Installing Jon's service-catalog repo"
	mkdir -p /root/copejon && cd /root/copejon
	git clone https://github.com/copejon/service-catalog.git
	cd -
	
	# Kubeadm init
	echo "-- Initializing via kubeadm..."
	echo "To join nodes to the master, run this on each node: " >> $NEXT_STEPS_FILE
	kubeadm init --pod-network-cidr=10.244.0.0/16 | tee >(sed -n '/kubeadm join --token/p' >> $NEXT_STEPS_FILE)
	mkdir -p /root/.kube
	sudo cp -f /etc/kubernetes/admin.conf /root/.kube/config
	sudo chown $(id -u):$(id -g) /root/.kube/config
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel-rbac.yml

	# write next (manual) steps to next_steps file
	cat <<EOF >$NEXT_STEPS_FILE

Perfom the following manual steps on the master node:

  # config the topology file:
  cp ${ROOT}/gluster-kubernetes-block-and-s3/deploy/topology.json.sample ${ROOT}/gluster-kubernetes-block-and-s3/deploy/topology.json
  # edit topology to contain hostname, ip and /dev/sdb devices from each node

  #run gk-deploy:
  cd ${ROOT}/gluster-kubernetes-block-and-s3/deploy
  ./gk-deploy topology.json -gvy --object-account=jcope --object-user=jcope --object-password=jcope --no-block

  # find gluster-s3 service endpoint
  kubectl get svc gluster-s3-service  #(cluster-ip:port)
  # modify s3-curl/s3curl.pl script: `my @endpoints = ( '<above-IP (no-port)>', )

  # create "bucket1"
  s3-curl/s3curl.pl --debug --id "jcope:jcope" --key "jcope" --put /dev/null -- -k -v http://gluster-s3-svc-ip:8080/bucket1
  # create object "bucket1/jeff"
  s3-curl/s3curl.pl --debug --id "jcope:jcope" --key "jcope" --put /dev/null -- -k -v http://10 .108.227.247:8080/bucket1/jeff
  # create local file: stuff.txt with content...
  # create object from local file
  s3-curl/s3curl.pl --debug --id "jcope:jcope" --key "jcope" --put stuff.txt -- -k -v http://10 .108.227.247:8080/bucket1/jeff
  # get object "bucket1/jeff"
  s3-curl/s3curl.pl --debug --id "jcope:jcope" --key "jcope" -- -k -v http://10 .108.227.247:8080/bucket1/jeff
EOF
fi

touch $SUCCESS_FILE
echo "Start up completion!"
