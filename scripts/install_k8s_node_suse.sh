#!/bin/bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <master|worker> [join-command] [--disable-swap]
  master          Run full master setup (includes kubeadm init and Calico install)
  worker          Run worker setup. Provide the full 'kubeadm join ...' command as second argument
                  or paste it when prompted.
  --disable-swap  Disable swap (default: swap is ENABLED)

Examples:
  $0 master
  $0 master --disable-swap
  $0 worker "sudo kubeadm join 10.0.0.1:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
  $0 worker "sudo kubeadm join 10.0.0.1:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>" --disable-swap
EOF
  exit 1
}

if [ $# -lt 1 ]; then
  usage
fi

ROLE="$1"
JOIN_CMD=""
ENABLE_SWAP=true

# Parse arguments
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --disable-swap)
      ENABLE_SWAP=false
      shift
      ;;
    *)
      if [[ "$ROLE" == "worker" && -z "$JOIN_CMD" ]]; then
        JOIN_CMD="$1"
      fi
      shift
      ;;
  esac
done

if [[ "$ROLE" != "master" && "$ROLE" != "worker" ]]; then
  usage
fi

echo "Selected role: $ROLE"
echo "Swap enabled: $ENABLE_SWAP"

# Step 2: Configure swap based on flag
if [ "$ENABLE_SWAP" = true ]; then
  echo "=== Configuring system WITH swap support ==="
  
  # Uncomment swap entries in /etc/fstab if they were commented
  sudo sed -i '/swap/ s/^#//' /etc/fstab
  
  # Enable swap
  sudo swapon -a || echo "No swap devices found or already enabled"
  
  echo "Current swap status:"
  sudo swapon -s
  free -h
else
  echo "=== Disabling swap ==="
  sudo swapoff -a
  sudo sed -i '/ swap / s/^/#/' /etc/fstab
fi

# Step 3: Load containerd modules
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

# Step 4: Configure Kubernetes IPv4 networking
sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

# Step 5: Install Docker and dependencies using zypper
echo "=== Installing Docker and dependencies ==="
sudo zypper refresh
sudo zypper install -y docker
sudo systemctl enable docker
sudo systemctl start docker

sudo zypper install -y curl ca-certificates gnupg openvswitch python3 jq conntrack-tools

# Configure containerd
sudo mkdir -p /etc/containerd
sudo sh -c "containerd config default > /etc/containerd/config.toml"
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Step 6: Install Kubernetes components
echo "=== Adding Kubernetes repository ==="

# Create keyrings directory
sudo mkdir -p /etc/apt/keyrings

# Add Kubernetes repository for SUSE
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# For SUSE, we can use the rpm repository instead
sudo zypper addrepo --gpgcheck --refresh --priority 120 \
  --gpgkey https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key \
  https://pkgs.k8s.io/core:/stable:/v1.31/rpm/ \
  kubernetes

sudo zypper refresh

echo "=== Installing Kubernetes components ==="
sudo zypper install -y kubelet kubeadm kubectl

# Lock Kubernetes packages to prevent accidental upgrades
sudo zypper addlock kubelet kubeadm kubectl

# Enable kubelet service
sudo systemctl enable kubelet

# Step 6.5: Configure kubelet for swap if enabled
if [ "$ENABLE_SWAP" = true ]; then
  echo "=== Configuring kubelet for swap support ==="
  
  KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
  
  # Create kubelet config directory if it doesn't exist
  sudo mkdir -p /var/lib/kubelet
  
  # Create a drop-in configuration for kubelet
  sudo mkdir -p /etc/systemd/system/kubelet.service.d
  
  cat <<EOF2 | sudo tee /etc/systemd/system/kubelet.service.d/20-swap.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--fail-swap-on=false"
EOF2
  
  sudo systemctl daemon-reload
fi

if [[ "$ROLE" == "master" ]]; then
  # Step 7: Initialize Kubernetes cluster (only on master node)
  echo "=== Configuring firewall for master node ==="
  
  # SUSE uses firewalld
  sudo systemctl enable firewalld
  sudo systemctl start firewalld
  
  # Open required ports for Kubernetes master
  sudo firewall-cmd --permanent --add-port=6443/tcp    # Kubernetes API server
  sudo firewall-cmd --permanent --add-port=2379-2380/tcp  # etcd server client API
  sudo firewall-cmd --permanent --add-port=10250/tcp   # Kubelet API
  sudo firewall-cmd --permanent --add-port=10259/tcp   # kube-scheduler
  sudo firewall-cmd --permanent --add-port=10257/tcp   # kube-controller-manager
  sudo firewall-cmd --reload
  
  echo "=== Initializing Kubernetes cluster ==="
  if [ "$ENABLE_SWAP" = true ]; then
    sudo kubeadm init --pod-network-cidr=10.10.0.0/16 --ignore-preflight-errors=Swap
  else
    sudo kubeadm init --pod-network-cidr=10.10.0.0/16
  fi

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  # Configure kubelet config.yaml for swap after kubeadm init
  if [ "$ENABLE_SWAP" = true ]; then
    KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
    
    if [ -f "$KUBELET_CONFIG" ]; then
      echo "Updating kubelet configuration for swap..."
      sudo cp "$KUBELET_CONFIG" "${KUBELET_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
      
      # Update failSwapOn to false
      if grep -q "failSwapOn:" "$KUBELET_CONFIG"; then
        sudo sed -i 's/failSwapOn: true/failSwapOn: false/' "$KUBELET_CONFIG"
      else
        echo "failSwapOn: false" | sudo tee -a "$KUBELET_CONFIG" > /dev/null
      fi
      
      # Add memorySwap configuration if not present
      if ! grep -q "memorySwap:" "$KUBELET_CONFIG"; then
        cat << EOF3 | sudo tee -a "$KUBELET_CONFIG" > /dev/null
memorySwap:
  swapBehavior: LimitedSwap
EOF3
      fi
      
      sudo systemctl restart kubelet
      echo "Kubelet restarted with swap support"
    fi
  fi

  # Step 8: Install Calico network add-on plugin
  #kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
  #curl https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml -O
  #sed -i 's/cidr: 192\.168\.0\.0\/16/cidr: 10.10.0.0\/16/g' custom-resources.yaml
  #kubectl create -f custom-resources.yaml

  echo ""
  echo "=== Master setup complete ==="
  echo "To add workers, run the displayed 'kubeadm join' command on each worker node."
  echo ""
  echo "Join command will be displayed above. Save it for worker nodes."
else
  # Worker node flow
  echo "=== Configuring firewall for worker node ==="
  
  # SUSE uses firewalld
  sudo systemctl enable firewalld
  sudo systemctl start firewalld
  
  # Open required ports for Kubernetes worker
  sudo firewall-cmd --permanent --add-port=10250/tcp   # Kubelet API
  sudo firewall-cmd --permanent --add-port=30000-32767/tcp  # NodePort Services
  sudo firewall-cmd --reload
  
  if [ -z "$JOIN_CMD" ]; then
    echo "No join command provided. Paste the full 'kubeadm join ...' command (including sudo if required), then press Enter:"
    read -r JOIN_CMD
  fi

  if [ -z "$JOIN_CMD" ]; then
    echo "No join command supplied. Exiting."
    exit 1
  fi

  # Run the join command with swap ignore if needed
  echo "Running join command..."
  if [ "$ENABLE_SWAP" = true ]; then
    # Add --ignore-preflight-errors=Swap if not already present
    if [[ ! "$JOIN_CMD" =~ "--ignore-preflight-errors" ]]; then
      JOIN_CMD="$JOIN_CMD --ignore-preflight-errors=Swap"
    fi
  fi
  
  eval "$JOIN_CMD"

  # Configure kubelet config.yaml for swap after joining
  if [ "$ENABLE_SWAP" = true ]; then
    KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
    
    if [ -f "$KUBELET_CONFIG" ]; then
      echo "Updating kubelet configuration for swap..."
      sudo cp "$KUBELET_CONFIG" "${KUBELET_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
      
      # Update failSwapOn to false
      if grep -q "failSwapOn:" "$KUBELET_CONFIG"; then
        sudo sed -i 's/failSwapOn: true/failSwapOn: false/' "$KUBELET_CONFIG"
      else
        echo "failSwapOn: false" | sudo tee -a "$KUBELET_CONFIG" > /dev/null
      fi
      
      # Add memorySwap configuration if not present
      if ! grep -q "memorySwap:" "$KUBELET_CONFIG"; then
        cat << EOF4 | sudo tee -a "$KUBELET_CONFIG" > /dev/null
memorySwap:
  swapBehavior: LimitedSwap
EOF4
      fi
      
      sudo systemctl restart kubelet
      echo "Kubelet restarted with swap support"
    fi
  fi

  echo "Worker node has joined the cluster (if the join command succeeded)."
fi

echo ""
echo "=== Setup Complete ==="
if [ "$ENABLE_SWAP" = true ]; then
  echo "Swap is ENABLED with LimitedSwap behavior"
  sudo swapon -s
else
  echo "Swap is DISABLED"
fi

echo ""
echo "SUSE-specific notes:"
echo "- Using firewalld instead of ufw"
echo "- Using zypper for package management"
echo "- Kubernetes packages locked with 'zypper addlock'"