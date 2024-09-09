#!/bin/bash
set -e

# Kubernetes Version: 1.30

# Section: Swap configuration
# Ensure swap is disabled temporarily
sudo swapoff -a &&\

# Disable swap permanently; create backup and disable swap
sudo sed -i.bak '/^[^#]/ s/\(^.*swap.*$\)/#\1/' /etc/fstab &&\

# Section: Network configuration
# To manually enable IPv4 packet forwarding
# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system &&\

# TODO: implement net.ipv4.ip_forward is set to 1 verification

sleep 4 &&\

# Step 1: Installing containerd
echo "installing containerd"
sudo wget https://github.com/containerd/containerd/releases/download/v1.7.21/containerd-1.7.21-linux-arm64.tar.gz &&\

sudo tar Cxzvf /usr/local containerd-1.7.21-linux-arm64.tar.gz &&\

# Start containerd as a systemd service
sudo wget https://raw.githubusercontent.com/containerd/containerd/main/containerd.service -P /usr/local/lib/systemd/system &&\

sudo systemctl daemon-reload &&\
sudo systemctl enable --now containerd &&\

sleep 4 &&\

# INSTALLING runc
echo "installing runc"
sudo wget https://github.com/opencontainers/runc/releases/download/v1.1.13/runc.arm64 &&\
sudo install -m 755 runc.arm64 /usr/local/sbin/runc &&\

# INSTALLING CNI plugins
sudo wget https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-arm-v1.5.1.tgz &&\
sudo mkdir -p /opt/cni/bin &&\
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-arm-v1.5.1.tgz &&\

sleep 5 &&\

# INSTALLING nerdctl commandline utility[client]
echo "Installing nerdctl"
sudo wget https://github.com/containerd/nerdctl/releases/download/v1.7.6/nerdctl-1.7.6-linux-arm64.tar.gz &&\

# Unpack the file with:
sudo tar Cxzvf /usr/local/bin nerdctl-1.7.6-linux-arm64.tar.gz &&\

# Configure the system for rootless
# Install the necessary dependencies
# sudo apt-get install uidmap -y &&\

# Next, install RootlessKit with:
sudo apt-get update &&\
sudo apt-get install rootlesskit -y &&\

# First, create a new systemd file with:
cat <<EOF | sudo tee /etc/sysctl.d/99-rootless.conf
kernel.unprivileged_userns_clone=1
EOF

# Enabling CPU, CPUSET, and I/O delegation
echo "Enabling CPU, CPUSET, and I/O delegation"
# By default, a non-root user can only get memory controller and pids controller to be delegated.
# To allow delegation of other controllers such as cpu, cpuset, and io, run the following commands:
sudo mkdir -p /etc/systemd/system/user@.service.d &&\
cat <<EOF | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
[Service]
Delegate=cpu cpuset io memory pids
EOF

sleep 5 &&\

sudo systemctl daemon-reload &&\
# Delegating cpuset is recommended as well as cpu. Delegating cpuset requires systemd 244 or later.
# After changing the systemd configuration, you need to re-login or reboot the host. Rebooting the host is recommended.

/usr/local/bin/containerd-rootless-setuptool.sh install &&\

# Customizing containerd
echo "# Customizing containerd"
sudo mkdir -p /etc/containerd/ &&\

# containerd config default > /etc/containerd/config.toml &&\
containerd config default | sudo tee  /etc/containerd/config.toml &&\

# Configuring the systemd cgroup driver set SystemdCgroup = true 
sudo sed -i.bak '/SystemdCgroup/s/false/true/' /etc/containerd/config.toml &&\

# Installing kubeadm, kubelet and kubectl 
echo "Installing kubeadm, kubelet and kubectl "

sudo apt-get update &&\

# apt-transport-https may be a dummy package; if so, you can skip that package
sudo apt-get install -y apt-transport-https ca-certificates curl gpg &&\

# Download the public signing key for the Kubernetes package repositories
# If the directory `/etc/apt/keyrings` does not exist, it should be created before the curl command, read the note below
# sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg &&\

# Add the appropriate Kubernetes apt repository.
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list &&\

# Update the apt package index, install kubelet, kubeadm and kubectl, and pin their version:
sudo apt-get update &&\
sudo apt-get install -y kubelet kubeadm kubectl &&\
sudo apt-mark hold kubelet kubeadm kubectl &&\

# Initializing kubeadm
export IPADDR=$(ip addr show eth1 | grep -Po 'inet \K[\d.]+')
export NODENAME=$(hostname -s)
export POD_CIDR="10.244.0.0/16"
sudo kubeadm init --apiserver-advertise-address=$IPADDR  --apiserver-cert-extra-sans=$IPADDR  --pod-network-cidr=$POD_CIDR --node-name $NODENAME --ignore-preflight-errors NumCPU &&\

# Your Kubernetes control-plane has initialized successfully!
# To start using your cluster, you need to run the following as a regular user:
mkdir -p $HOME/.kube &&\
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config &&\
sudo chown $(id -u):$(id -g) $HOME/.kube/config &&\
