#! /bin/bash

# These values are currently coded into the startup-basic.sh script.
# Initally though I would need them in gk-up.sh, but decided it wasn't
# necessary at the moment.  I figured I wrote it, maybe it'll be handy
# before this script is done.

DOCKER_DEP="docker-1.12.6"
FUSE_DEP="glusterfs-fuse"
UNZIP_DEP="unzip"
KUBECTL_DEP="https://storage.googleapis.com/kubernetes-release/release/v.1.7.4/bin/linux/amd64/kubectl"
KUBEADM_REPO="
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF"
KUBELET_DEP="kubelet"
KUBEADM_DEP="kubeadm"
HEKETI_DEP="https://github.com/heketi/heketi/releases/download/v4.0.0/heketi-client-v4.0.0.linux.amd64.tar.gz"
GK_S3_DEP="https://github.com/jarrpa/gluster-kubernetes/archive/block-and-s3.tar.gz"
S3_CURL_DEP="http://s3.amazonaws.com/doc/s3-example-code/s3-curl.zip"
KUBEADM_CONFIG_FLANNELD="--pod-network-cidr=10.244.0.0/16"
KUBE_FLANNEL="https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"
KBUE_FLANNEL_RBAC="https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel-rbac.yml"
