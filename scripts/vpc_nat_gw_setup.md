# Kube-OVN External Network Setup Guide

This guide sets up external network connectivity for VMs using Kube-OVN with Multus CNI, VPC NAT Gateway, and Floating IPs.

## Prerequisites

- Kubernetes cluster with Kube-OVN installed
- Multus CNI installed
- Physical network interface available on nodes

## Configuration

Set the following environment variables according to your environment:

```bash
EXT_NIC="eno1"                  # The physical network interface on each Kubernetes node to bridge for external access
EXT_IP_RANGE="192.168.10.0/24"  # The external/physical network subnet CIDR used for floating IPs and NAT gateways
EXT_GW="192.168.10.1"           # Gateway IP of the physical/core network (usually your router)
FIP_STATIC_IP="192.168.10.101"  # Floating IP from EXT_IP_RANGE to be mapped for external SSH/access (should not be in excludeIps)
VM_CIDR="10.17.3.0/24"          # Overlay network subnet CIDR for VMs ("internal" VM network)
VM_CIDR_GW="10.17.3.1"          # Gateway IP for VM overlay subnet (should be .1 of VM_CIDR)
VM_INTERNAL_IP="10.17.3.2"      # Example VM IP assigned from VM_CIDR (will map FIP to this)
NAT_GW_IP="10.17.3.254"         # Internal overlay IP for NAT Gateway Pod (should be in VM_CIDR, ideally .254)
STABLE_NODE="labcp0"            # Name of node on which to anchor (force schedule) the VPC NAT Gateway for egress
```

## Step 1: Install Multus CNI
```bash
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml
```

## Step 2: Configure MacVTap Interface

On `$STABLE_NODE`, run the following commands to create the macvtap interface:

```bash
sudo ip link add link $EXT_NIC name macvtap0 type macvtap mode bridge
sudo ip link set macvtap0 up
```

## Step 3: Create Network Attachment Definitions

Create the NetworkAttachmentDefinition resources for external network connectivity.

**Note:** The name is set to 'external-subnet' to match the Subnet name.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: external-subnet
  namespace: kube-system
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "ovn-vpc-external-network",
      "type": "macvlan",
      "master": "$EXT_NIC",
      "mode": "bridge",
      "ipam": {
        "type": "kube-ovn",
        "server_socket": "/run/openvswitch/kube-ovn-daemon.sock",
        "provider": "ovn-vpc-external-network.kube-system"
      }
    }'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ovn-vpc-external-network
  namespace: kube-system
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "ovn-vpc-external-network",
      "type": "macvlan",
      "master": "$EXT_NIC",
      "mode": "bridge",
      "ipam": {
        "type": "kube-ovn",
        "server_socket": "/run/openvswitch/kube-ovn-daemon.sock",
        "provider": "ovn-vpc-external-network.kube-system"
      }
    }'
EOF
```

## Step 4: Create External Subnets

Create the external and VM subnets:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: external-subnet
spec:
  protocol: IPv4
  cidrBlock: $EXT_IP_RANGE
  gateway: $EXT_GW
  provider: external-subnet.kube-system
  excludeIps: ["192.168.10.1..192.168.10.99"]
---
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: vm-subnet
spec:
  cidrBlock: $VM_CIDR
  excludeIps:
  - $VM_CIDR_GW
  gateway: $VM_CIDR_GW
  gatewayType: distributed
  natOutgoing: false
  vpc: ovn-cluster
EOF
```

## Step 5: Configure VPC NAT Gateway

```bash
cat <<EOF | kubectl apply -f -
apiVersion: kubeovn.io/v1
kind: VpcNatGateway
metadata:
  name: ovn-external-gw
  namespace: kube-system
spec:
  vpc: ovn-cluster
  subnet: vm-subnet          # This triggers the Pod to get a 10.17.3.x IP
  lanIp: $NAT_GW_IP          # The "Internal Door" for the VMs
  externalSubnets:
    - external-subnet
  selector:
    - "kubernetes.io/hostname: $STABLE_NODE"
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
EOF
```

## Step 6: Update NAT Gateway Image

Patch the statefulset to use a specific image version:

```bash
kubectl patch statefulset vpc-nat-gw-ovn-external-gw -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"vpc-nat-gw","image":"kubeovn/vpc-nat-gateway:v1.14.5"}]}}}}'
```

## Step 7: Apply NAT Rules

Create the Floating IP (FIP) rules for external access:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: kubeovn.io/v1
kind: IptablesEIP
metadata:
  name: vm-fip-eip
spec:
  natGwDp: ovn-external-gw
  v4ip: $FIP_STATIC_IP
---
apiVersion: kubeovn.io/v1
kind: IptablesFIPRule
metadata:
  name: vm-fip-rule
spec:
  eip: vm-fip-eip
  internalIp: $VM_INTERNAL_IP
EOF
```

## Step 8: Configure Manual Routing Rules

**Note:** For some reason multi-subnet VPC is not working correctly, so we need to add route rules manually.

First, find the OVN leader pod and add routing policies:

```bash
LEADER_POD=$(kubectl get pods -n kube-system -l app=ovn-central -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | \
while read pod; do \
  if kubectl exec -n kube-system "$pod" -c ovn-central -- ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound | grep -q "Role: leader"; then \
    echo "$pod"; \
    break; \
  fi; \
done)

# Reroute all outbound traffic from the VM subnet to the NAT Pod's new IP
kubectl exec -it -n kube-system "$LEADER_POD" -c ovn-central -- \
ovn-nbctl lr-policy-add ovn-cluster 32000 "ip4.src == $VM_CIDR" reroute "$NAT_GW_IP"

# Allow traffic to the Service CIDR (CoreDNS Virtual IP)
kubectl exec -it -n kube-system "$LEADER_POD" -c ovn-central -- \
ovn-nbctl lr-policy-add ovn-cluster 32500 "ip4.dst == 10.96.0.0/12" allow

# Allow traffic to the Pod CIDR (CoreDNS Actual Pods)
kubectl exec -it -n kube-system "$LEADER_POD" -c ovn-central -- \
ovn-nbctl lr-policy-add ovn-cluster 32500 "ip4.dst == 10.16.0.0/16" allow

kubectl exec -it -n kube-system "$LEADER_POD" -c ovn-central -- \
ovn-nbctl lr-policy-list ovn-cluster
```