#!/bin/bash

# Exit on  error
set -e

# Variables
CONTAINERD_VERSION="1.7.21"  # adjust to latest stable version if needed

# Define directories
CONTAINERD_DIR="$HOME/.local/bin"
CONTAINERD_CONFIG_DIR="/etc/containerd/"
CONTAINERD_SYSTEMD_UNIT="$HOME/.config/systemd/user/containerd.service"

# Ensure swap is disabled temporarily
sudo swapoff -a &&\

# Disable swap permanently; create backup and disable swap
sudo sed -i.bak '/^[^#]/ s/\(^.*swap.*$\)/#\1/' /etc/fstab &&\

# Enable IPv4 packet forwarding (sysctl params required by setup, params persist across reboots)
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system &&\

# TODO: implement net.ipv4.ip_forward is set to 1 verification

sleep 4 &&\

# INSTALLING runc
echo "                             🐧 INSTALLING RUNC 🐧                            "

sudo wget -c --tries=0 --read-timeout=20 https://github.com/opencontainers/runc/releases/download/v1.1.13/runc.arm64 &&\
sudo install -m 755 runc.arm64 /usr/local/sbin/runc &&\

# INSTALLING CNI plugins
echo "                         🐧 INSTALLING CNI plugins 🐧                         "

sudo wget -c --tries=0 --read-timeout=20 https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-arm-v1.5.1.tgz &&\
sudo mkdir -p /opt/cni/bin &&\
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-arm-v1.5.1.tgz &&\

sleep 4 &&\

# INSTALLING CONTAINERD
echo "                         🐧 INSTALLING CONTAINERD 🐧                          "

# Install dependencies
install_dependencies() {
    echo "Installing dependencies..."
    sudo apt-get update
    sudo apt-get install -y btrfs-progs uidmap slirp4netns fuse-overlayfs rootlesskit
}

# Download and install containerd
install_containerd() {
    echo "Installing containerd..."
    sudo wget -c --tries=0 --read-timeout=20 https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION/containerd-$CONTAINERD_VERSION-linux-arm64.tar.gz &&\
    sudo tar Cxzvf /usr/local containerd-$CONTAINERD_VERSION-linux-arm64.tar.gz
    sudo mkdir -p "$CONTAINERD_CONFIG_DIR"

}

# Set up containerd configuration
setup_containerd_config() {
    echo "Setting up containerd config..."
    if [ ! -f "$CONTAINERD_CONFIG_DIR/config.toml" ]; then
        echo "Config file not found, generating default containerd config."
        containerd config default | sudo tee "$CONTAINERD_CONFIG_DIR/config.toml"
    fi
    # Modify the configuration file to enable rootless mode
    sudo sed -i.bak '/SystemdCgroup/s/false/true/' $CONTAINERD_CONFIG_DIR/config.toml
}

# Define desired sandbox image
set_sandbox_image() {
    SANDBOX_IMAGE="registry.k8s.io/pause:3.10"
    # Check if the configuration contains the [plugins."io.containerd.grpc.v1.cri"].sandbox_image entry
    if grep -q 'sandbox_image' "$CONTAINERD_CONFIG_DIR/config.toml"; then
        # Update the existing sandbox image line with the custom image
        sudo sed -i "s|sandbox_image = \".*\"|sandbox_image = \"$SANDBOX_IMAGE\"|" "$CONTAINERD_CONFIG_DIR/config.toml"
    else
        # Add the sandbox_image configuration if it's not present
        sudo sed -i '/\[plugins."io.containerd.grpc.v1.cri"\]/a\ \ \ \ sandbox_image = "'"$SANDBOX_IMAGE"'"' "$CONTAINERD_CONFIG_DIR/config.toml"
    fi
}

# Set up containerd as a systemd user service
setup_systemd_service() {
    echo "Setting up systemd service for containerd..."
    sudo wget -c --tries=0 --read-timeout=20 https://raw.githubusercontent.com/containerd/containerd/main/containerd.service -P /usr/local/lib/systemd/system &&\
    sudo systemctl daemon-reload &&\
    sudo systemctl enable --now containerd &&\
    sleep 4
}

# Add user to sub{uid,gid} if not already added
setup_subuid_subgid() {
    echo "Setting up subuid and subgid..."
    if ! grep "^$(whoami):" /etc/subuid &>/dev/null; then
        echo "$(whoami):100000:65536" | sudo tee -a /etc/subuid
    fi
    if ! grep "^$(whoami):" /etc/subgid &>/dev/null; then
        echo "$(whoami):100000:65536" | sudo tee -a /etc/subgid
    fi
}


# Install nerdctl commandline utility[client] and enable rootless mode
enable_rootless_mode() {
    echo "                           🐧 INSTALLING NERDCTL 🐧                           "
    sudo wget -c --tries=0 --read-timeout=20 https://github.com/containerd/nerdctl/releases/download/v1.7.6/nerdctl-1.7.6-linux-arm64.tar.gz &&\
    # Unpack the file with:
    sudo tar Cxzvf /usr/local/bin nerdctl-1.7.6-linux-arm64.tar.gz &&\
    echo "Enabling rootless mode..."
    containerd-rootless-setuptool.sh install
}

# Start installation
install_dependencies
install_containerd
setup_containerd_config
set_sandbox_image
setup_systemd_service
setup_subuid_subgid
enable_rootless_mode

echo "Rootless Containerd installation completed!"

# Variables
K8S_VERSION="1.31"  # adjust to latest stable version if needed

# INSTALLING kubeadm, kubelet and kubectl: You will install these packages on all of your machines
echo "                   🐧 INSTALLING KUBEADM/KUBELET/KUBECTL 🐧                   "

sudo apt-get update &&\

# apt-transport-https may be a dummy package; if so, you can skip that package
sudo apt-get install -y apt-transport-https ca-certificates curl gpg &&\

# Download the public signing key for the Kubernetes package repositories
# If the directory `/etc/apt/keyrings` does not exist, it should be created before the curl command, read the note below
# sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg &&\

# Add the appropriate Kubernetes apt repository.
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list &&\

# Update the apt package index, install kubelet, kubeadm and kubectl, and pin their version:
sudo apt-get update &&\
sudo apt-get install -y kubelet kubeadm kubectl &&\
sudo apt-mark hold kubelet kubeadm kubectl &&\

# INITIALIZING KUBEADM
export IPADDR=$(ip addr show eth1 | grep -Po 'inet \K[\d.]+')
export NODENAME=$(hostname -s)
export POD_CIDR="10.244.0.0/16"
sudo kubeadm init --apiserver-advertise-address=$IPADDR  --apiserver-cert-extra-sans=$IPADDR  --pod-network-cidr=$POD_CIDR --node-name $NODENAME --ignore-preflight-errors NumCPU &&\

# Your Kubernetes control-plane has initialized successfully!
# To start using your cluster, you need to run the following as a regular user:
mkdir -p $HOME/.kube &&\
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config &&\
sudo chown $(id -u):$(id -g) $HOME/.kube/config
