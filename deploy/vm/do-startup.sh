#! /bin/bash
### TODOs
# parse gluster-s3-ep socket.
###
ROOT=/root
LOG_FILE=${ROOT}/start-script.log
SUCCESS_FILE=${ROOT}/__STARTUP_SUCCESS
FAIL_FILE=$ROOT/__STARTUP_FAIL
NEXT_STEPS_FILE=${ROOT}/next_steps
GOPATH=$ROOT/go

on-success () { touch $SUCCESS_FILE; }

on-fail () { touch $FAIL_FILE; }

set -eo pipefail

if [ $(id -u) != 0  ]; then
	echo "!!! Switching to root  !!!"
	sudo su
fi

echo "-- Changing to $ROOT dir"
cd $ROOT

exec 3>&1 4>&2
trap $( exec 1>&3 2>&4 && on-success ) 0
trap $( exec 1>&3 2>&4 && on-fail ) 1 2 3
exec 1>${LOG_FILE} 2>&1

echo "============================================="
echo "               Start-Up Script"
echo "============================================="

echo "-- Stopping Firewall"
systemctl stop firewalld && systemctl disable firewalld
echo "-- Disabling SELinux"
setenforce 0

echo "-- Configuring SSH"
sed -i 's#PermitRootLogin no#PermitRootLogin yes#' /etc/ssh/sshd_config
systemctl restart sshd

# Docker
echo "-- Installing Docker"
yum install docker-1.12.6 -y -q -e 0

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
	echo "-- Looks like this is the master node. Doing extra initialization."

	cat <<EOF >>/root/.bashrc
source /root/.kube/completion
alias kc=kubectl
export GOPATH=$GOPATH
export PATH=\$PATH:/usr/local/bin
EOF
	# Reload bash_profile
	source .bash_profile
	# QoL Setup
	echo "-- Yum installing bash-completion, tmux, unzip"
	yum install bash-completion tmux unzip -y -q -e 0
	echo "-- Pulling in custom tmux.conf"
	curl -sSLO https://raw.githubusercontent.com/copejon/sandbox/master/.tmux.conf
	echo "-- Setting up kube completion"
	mkdir -p .kube/
	kubectl completion bash > .kube/completion

	# Gluster-Kubernetes
	echo "-- Getting gluster-kubernetes (s3 and block)"
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
	curl -sSL https://storage.googleapis.com/kubernetes-helm/helm-v2.5.0-linux-amd64.tar.gz | tar zx -C /tmp/
	mv $(find /tmp/ -name helm) /usr/bin/
	chmod +x /usr/bin/helm
	rm -rf /tmp/linux-amd64

	# socat
	echo "-- Installing socat"
	yum install socat -y -q -e 0

	# golang
	echo "-- Installing golang"
	yum install golang -y -q -e 0

	# minio-go
	echo "-- Installing minio"
	go get -u github.com/minio/minio-go

	# heketi-cli
	echo "-- Installing heketi-client"
	curl -sSL https://github.com/heketi/heketi/releases/download/v4.0.0/heketi-client-v4.0.0.linux.amd64.tar.gz | tar -xz -C /tmp/
	mv $(find /tmp/ -name heketi-cli) /usr/bin/
	chmod +x /usr/bin/heketi-cli

	# git
	echo "-- Installing git"
	yum install git -y -q -e 0

	# demo service-catalog repo
	echo "-- Installing demo service-catalog repo"
	SCPATH=$GOPATH/src/github.com/kubernetes-incubator
	mkdir -p $SCPATH
	git clone https://github.com/copejon/service-catalog.git $SCPATH/service-catalog
	
	printf "=== Setup Is almost complete! ==\n=== Do the following steps in order.\n" > $NEXT_STEPS_FILE

	# Kubeadm init
	echo "-- Initializing via kubeadm..."
	printf "To join nodes to the master, run this on each node: " >> $NEXT_STEPS_FILE
	kubeadm init --pod-network-cidr=10.244.0.0/16 | tee >(sed -n '/kubeadm join --token/p' >> $NEXT_STEPS_FILE)
	mkdir -p $ROOT/.kube
	sudo cp -f /etc/kubernetes/admin.conf $ROOT/.kube/config
	sudo chown $(id -u):$(id -g) $ROOT/.kube/config
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel-rbac.yml

	# write next (manual) steps to next_steps file
	cat <<EOF >>$NEXT_STEPS_FILE

Perfom the following manual steps on the master node:

  # config the topology file:
  cp ${ROOT}/gluster-kubernetes-block-and-s3/deploy/topology.json.sample ${ROOT}/gluster-kubernetes-block-and-s3/deploy/topology.json
  # edit topology to contain hostname, ip and /dev/sdb devices from each node

  #run gk-deploy:
  cd ${ROOT}/gluster-kubernetes-block-and-s3/deploy
  ./gk-deploy topology.json -gvy --object-account=jcope --object-user=jcope --object-password=jcope --no-block

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

touch $SUCCESS_FILE
echo "Start up completion!"
