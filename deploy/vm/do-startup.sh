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
	yum install bash-completion tmux unzip -y
	curl -sSLO https://raw.githubusercontent.com/copejon/sandbox/master/.tmux.conf
	mkdir -p /root/.kube
	kubectl completion bash > /root/.kube/completion
	cat <<EOF >>/root/.bashrc
alias kc=kubectl
source /root/.kube/completion
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

	# Kubeadm
	echo "-- Installing heketi-client"
	curl -sSL https://github.com/heketi/heketi/releases/download/v4.0.0/heketi-client-v4.0.0.linux.amd64.tar.gz | tar -xz
	mv $(find ./ -name heketi-cli) /usr/bin/
	
	# Kubeadm Init
	echo "-- Initializing via kubeadm..."
	kubeadm init --pod-network-cidr=10.244.0.0/16 | tee >(sed -n '/kubeadm join --token/p' >> $NEXT_STEPS_FILE)
	mkdir -p /root/.kube
	sudo cp -f /etc/kubernetes/admin.conf /root/.kube/config
	sudo chown $(id -u):$(id -g) /root/.kube/config
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel-rbac.yml

	# write next (manual) steps to next_steps_file
	echo \
"Setup the topology file:
    cp ${ROOT}/gluster-kubernetes-block-and-s3/deploy/topology.json.sample ${ROOT}/gluster-kubernetes-block-and-s3/deploy/topology.json" >> $NEXT_STEPS_FILE
	echo \
"Run gk-deploy:
    cd ${ROOT}/gluster-kubernetes-block-and-s3/deploy
    ./gk-deploy topology.json -gvy --object-account=jcope --object-user=jcope --object-password=jcope" >> $NEXT_STEPS_FILE
fi

touch $SUCCESS_FILE
echo "Start up completion!"
