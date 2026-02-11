#!/bin/bash
# generate-vms.sh - Generate KubeVirt VMs from template with optional NFS storage

# Configuration
NAMESPACE="default"
NUM_VMS=4
BASE_NAME="vm"
MEMORY="8Gi"
CPU_CORES="8"
OVERCOMMIT=8
OS_IMAGE="quay.io/containerdisks/ubuntu:24.04"  # Ubuntu 24.04 LTS container disk

# NFS Configuration (optional)
USE_NFS=false
NFS_SERVER=""
NFS_PATH=""
DISK_SIZE="100Gi"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --ssh-key)
      SSH_PUBLIC_KEY="$2"
      shift 2
      ;;
    --ssh-key-file)
      SSH_PUBLIC_KEY=$(cat "$2")
      shift 2
      ;;
    --num-vms)
      NUM_VMS="$2"
      shift 2
      ;;
    --memory)
      MEMORY="$2"
      shift 2
      ;;
    --cpu)
      CPU_CORES="$2"
      shift 2
      ;;
    --os-image)
      OS_IMAGE="$2"
      shift 2
      ;;
    --use-nfs)
      USE_NFS=true
      shift
      ;;
    --nfs-server)
      NFS_SERVER="$2"
      USE_NFS=true
      shift 2
      ;;
    --nfs-path)
      NFS_PATH="$2"
      shift 2
      ;;
    --disk-size)
      DISK_SIZE="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --ssh-key-file PATH    Path to SSH public key file (default: auto-detect)"
      echo "  --ssh-key KEY          SSH public key string"
      echo "  --num-vms N            Number of VMs to generate (default: 4)"
      echo "  --memory SIZE          Memory per VM (default: 8Gi)"
      echo "  --cpu CORES            CPU cores per VM (default: 8)"
      echo "  --os-image IMAGE       Container disk image (default: quay.io/containerdisks/ubuntu:24.04)"
      echo ""
      echo "NFS Storage Options:"
      echo "  --use-nfs              Enable NFS persistent storage (uses containerDisk by default)"
      echo "  --nfs-server IP        NFS server IP address"
      echo "  --nfs-path PATH        NFS base path (VM subdirs will be created)"
      echo "  --disk-size SIZE       Disk size for NFS volumes (default: 100Gi)"
      echo ""
      echo "  --help                 Show this help message"
      echo ""
      echo "Examples:"
      echo "  # Using containerDisk (ephemeral):"
      echo "  $0 --ssh-key-file ~/.ssh/id_rsa.pub --num-vms 3"
      echo ""
      echo "  # Using NFS persistent storage:"
      echo "  $0 --use-nfs --nfs-server 192.168.10.100 --nfs-path /srv/kubevirt_storage/vm-disks"
      echo ""
      echo "  # Custom resources:"
      echo "  $0 --memory 16Gi --cpu 16 --disk-size 200Gi"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Validate NFS configuration if enabled
if [ "$USE_NFS" = true ]; then
    if [ -z "$NFS_SERVER" ] || [ -z "$NFS_PATH" ]; then
        echo "Error: When using --use-nfs, both --nfs-server and --nfs-path are required"
        echo "Example: --nfs-server 192.168.10.100 --nfs-path /srv/kubevirt_storage/vm-disks"
        exit 1
    fi
fi

# Auto-detect SSH public key if not provided
if [ -z "$SSH_PUBLIC_KEY" ]; then
    if [ -f ~/.ssh/id_rsa.pub ]; then
        SSH_PUBLIC_KEY=$(cat ~/.ssh/id_rsa.pub)
        echo "Using SSH key: ~/.ssh/id_rsa.pub"
    elif [ -f ~/.ssh/id_ed25519.pub ]; then
        SSH_PUBLIC_KEY=$(cat ~/.ssh/id_ed25519.pub)
        echo "Using SSH key: ~/.ssh/id_ed25519.pub"
    elif [ -f ~/.ssh/id_ecdsa.pub ]; then
        SSH_PUBLIC_KEY=$(cat ~/.ssh/id_ecdsa.pub)
        echo "Using SSH key: ~/.ssh/id_ecdsa.pub"
    else
        echo "Warning: No SSH public key found in ~/.ssh/"
        echo "VMs will only have password authentication enabled"
        echo "Generate a key with: ssh-keygen"
        echo ""
        SSH_PUBLIC_KEY=""
    fi
fi

# Function to calculate memory request
calculate_memory_request() {
    local memory=$1
    local overcommit=$2
    
    # Extract number and unit
    local value=$(echo $memory | sed 's/[^0-9.]//g')
    local unit=$(echo $memory | sed 's/[0-9.]//g')
    
    # Calculate request based on unit
    if [[ $unit == "Gi" || $unit == "G" ]]; then
        # Convert to Mi: Gi * 1024 / overcommit
        local result=$(echo "scale=0; ($value * 1024) / $overcommit" | bc)
        echo "${result}Mi"
    elif [[ $unit == "Mi" || $unit == "M" ]]; then
        # Already in Mi: just divide
        local result=$(echo "scale=0; $value / $overcommit" | bc)
        echo "${result}Mi"
    else
        echo "Error: Unsupported memory unit $unit" >&2
        exit 1
    fi
}

# Function to calculate CPU request in millicores
calculate_cpu_request() {
    local cpu_cores=$1
    local overcommit=$2
    
    # Convert cores to millicores and divide by overcommit
    # e.g., 2 cores / 8 = 0.25 cores = 250m
    local millicores=$(echo "scale=0; ($cpu_cores * 1000) / $overcommit" | bc)
    
    echo "${millicores}m"
}

# Calculate requests dynamically
MEMORY_REQUEST=$(calculate_memory_request $MEMORY $OVERCOMMIT)
CPU_REQUEST=$(calculate_cpu_request $CPU_CORES $OVERCOMMIT)

echo "=== Resource Calculation ==="
if [ "$USE_NFS" = true ]; then
    echo "Storage: NFS Persistent (${NFS_SERVER}:${NFS_PATH})"
    echo "  Disk Size: ${DISK_SIZE}"
else
    echo "Storage: Container Disk (ephemeral)"
    echo "  OS Image: ${OS_IMAGE}"
fi
echo "Limits:"
echo "  Memory: ${MEMORY}"
echo "  CPU: ${CPU_CORES} cores"
echo ""
echo "Overcommit: ${OVERCOMMIT}x"
echo ""
echo "Calculated Requests:"
echo "  Memory: ${MEMORY_REQUEST} (${MEMORY} / ${OVERCOMMIT})"
echo "  CPU: ${CPU_REQUEST} (${CPU_CORES} cores / ${OVERCOMMIT})"
echo ""

# Function to generate cloud-init user data
generate_cloud_init() {
    local hostname=$1
    
    # Build cloud-init config
    local cloud_init="#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.local
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: sudo
    shell: /bin/bash"

    # Add SSH key if available
    if [ -n "$SSH_PUBLIC_KEY" ]; then
        cloud_init="${cloud_init}
    ssh-authorized-keys:
      - ${SSH_PUBLIC_KEY}"
    fi

    cloud_init="${cloud_init}
  - name: core
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: sudo
    shell: /bin/bash"

    # Add SSH key for core user if available
    if [ -n "$SSH_PUBLIC_KEY" ]; then
        cloud_init="${cloud_init}
    ssh-authorized-keys:
      - ${SSH_PUBLIC_KEY}"
    fi

    cloud_init="${cloud_init}
chpasswd:
  list: |
    ubuntu:ubuntu
    core:core
  expire: False
ssh_pwauth: True
package_update: false
package_upgrade: false
runcmd:
  - hostnamectl set-hostname ${hostname}
  - echo \"127.0.0.1 ${hostname}\" >> /etc/hosts
  - systemctl restart systemd-hostnamed"

    echo "$cloud_init" | base64 -w0
}

# Function to generate PV
generate_pv() {
    local vm_name=$1
    cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${vm_name}-disk-pv
spec:
  capacity:
    storage: ${DISK_SIZE}
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_PATH}/${vm_name}
EOF
}

# Function to generate PVC
generate_pvc() {
    local vm_name=$1
    cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${vm_name}-disk-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: ${DISK_SIZE}
  storageClassName: ""
  volumeName: ${vm_name}-disk-pv
EOF
}

# Function to generate VM
generate_vm() {
    local vm_name=$1
    local hostname=$2
    local cloud_init_data=$(generate_cloud_init ${hostname})
    
    cat <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${vm_name}
  namespace: ${NAMESPACE}
  labels:
    app: ${vm_name}
    kubevirt.io/vm: ${vm_name}
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${vm_name}
        app: ${vm_name}
      annotations:
        # MANDATORY for seamless live migration in Kube-OVN
        kubevirt.io/allow-pod-bridge-network-live-migration: "true"
        #"ovn.kubernetes.io/logical_switch": "vm-subnet"
        # This locks the IP so your FIP rule never breaks
        # ovn.kubernetes.io/ip_address: "10.17.3.50"
    spec:
      evictionStrategy: LiveMigrate  # This enables automatic migration on drain
      domain:
        cpu:
          cores: ${CPU_CORES}
        memory:
          guest: ${MEMORY}
        devices:
          disks:
EOF

    # Add disk configuration based on storage type
    if [ "$USE_NFS" = true ]; then
        cat <<EOF
          - name: disk0
            disk:
              bus: virtio
EOF
    else
        cat <<EOF
          - name: containerdisk
            disk:
              bus: virtio
EOF
    fi

    cat <<EOF
          - name: cloudinit
            disk:
              bus: virtio
          interfaces:
          - name: default
            bridge: {}
        machine:
          type: q35
        resources:
          requests:
            memory: ${MEMORY_REQUEST}
            cpu: ${CPU_REQUEST}
          limits:
            memory: ${MEMORY}
      networks:
      - name: default
        pod: {}
      volumes:
EOF

    # Add volume configuration based on storage type
    if [ "$USE_NFS" = true ]; then
        cat <<EOF
      - name: disk0
        persistentVolumeClaim:
          claimName: ${vm_name}-disk-pvc
EOF
    else
        cat <<EOF
      - name: containerdisk
        containerDisk:
          image: ${OS_IMAGE}
EOF
    fi

    cat <<EOF
      - name: cloudinit
        cloudInitNoCloud:
          userDataBase64: "${cloud_init_data}"
EOF
}

# Main execution
echo "=== Generating KubeVirt VM manifests ==="
echo ""

# Generate all-in-one YAML file
OUTPUT_FILE="all-vms.yaml"
> ${OUTPUT_FILE}  # Clear file

for i in $(seq 1 ${NUM_VMS}); do
    VM_NAME="${BASE_NAME}${i}"
    HOSTNAME="${BASE_NAME}${i}"
    
    echo "Generating manifests for ${VM_NAME} (hostname: ${HOSTNAME})..."
    
    # Generate NFS resources if enabled
    if [ "$USE_NFS" = true ]; then
        # Generate PV
        generate_pv ${VM_NAME} >> ${OUTPUT_FILE}
        echo "---" >> ${OUTPUT_FILE}
        
        # Generate PVC
        generate_pvc ${VM_NAME} >> ${OUTPUT_FILE}
        echo "---" >> ${OUTPUT_FILE}
    fi
    
    # Generate VM
    generate_vm ${VM_NAME} ${HOSTNAME} >> ${OUTPUT_FILE}
    
    if [ $i -lt ${NUM_VMS} ]; then
        echo "---" >> ${OUTPUT_FILE}
    fi
done

echo ""
echo "✓ Generated ${OUTPUT_FILE}"
echo ""

# Additional NFS setup instructions
if [ "$USE_NFS" = true ]; then
    echo "=== NFS Setup Required ==="
    echo "Before deploying, create NFS directories on ${NFS_SERVER}:"
    echo ""
    for i in $(seq 1 ${NUM_VMS}); do
        echo "  mkdir -p ${NFS_PATH}/${BASE_NAME}${i}"
    done
    echo ""
    echo "Ensure NFS exports are configured in /etc/exports:"
    echo "  ${NFS_PATH} *(rw,sync,no_subtree_check,no_root_squash)"
    echo ""
    echo "Then run: exportfs -ra"
    echo ""
fi

echo "=== Access Information ==="
if [ -n "$SSH_PUBLIC_KEY" ]; then
    echo "SSH Key Authentication: Enabled"
    echo "  SSH access: virtctl ssh ubuntu@${BASE_NAME}1"
    echo "              virtctl ssh core@${BASE_NAME}1"
fi
echo "Password Authentication: Enabled"
echo "  Username: ubuntu | Password: ubuntu"
echo "  Username: core   | Password: core"
echo ""
echo "=== Deployment Commands ==="
echo "To deploy:"
echo "  kubectl apply -f ${OUTPUT_FILE}"
echo ""
echo "To check status:"
echo "  kubectl get vms"
echo "  kubectl get vmis"
if [ "$USE_NFS" = true ]; then
    echo "  kubectl get pv"
    echo "  kubectl get pvc"
fi
echo ""
echo "To access VMs via console:"
echo "  virtctl console ${BASE_NAME}1"
echo ""