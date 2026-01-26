
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml

# --- CONFIGURATION ---
EXT_NIC="eno1"                 # The physical interface on your K8s nodes
EXT_IP_RANGE="192.168.10.0/24"  # Your physical network CIDR
EXT_GW="192.168.10.1"           # Physical router gateway
FIP_STATIC_IP="192.168.10.101"  # The IP you will SSH into
VM_CIDR="10.17.3.0/24"
VM_CIDR_GW="10.17.3.1"
VM_INTERNAL_IP="10.17.3.2"    # Internal Overlay IP
NAT_GW_IP="10.17.3.254"        # Internal IP for the NAT Pod
STABLE_NODE="labcp0"        # Node to anchor the NAT Gateway


echo "On $STABLE_NODE run the bellow"
# Create it directly on eno1 (Untagged)
echo "sudo ip link add link $EXT_NIC name macvtap0 type macvtap mode bridge"
echo "sudo ip link set macvtap0 up"

echo "1. Creating Network Attachment Definition..."
# Note: Name changed to 'external-subnet' to match the Subnet name
cat <<EOF | kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: external-subnet
  namespace: kube-system
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "external-subnet",
      "type": "macvlan",
      "master": "$EXT_NIC",
      "mode": "bridge",
      "ipam": {
        "type": "kube-ovn",
        "server_socket": "/run/openvswitch/kube-ovn-daemon.sock",
        "provider": "external-subnet.kube-system"
      }
    }'
EOF

echo "2. Creating External Subnet..."
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

#kubectl patch subnet ovn-default --type='merge' -p '{"spec":{"excludeIps":["10.16.0.1","10.16.0.250..10.16.0.254"]}}'

echo "3. Configuring VPC Routing (The Reroute Strategy)..."
# Instead of manual ovn-nbctl, we tell the VPC to use the NAT GW for external traffic
# This automatically handles the reroute logic for the 10.16.0.0/16 range
cat <<EOF | kubectl apply -f -
apiVersion: kubeovn.io/v1
kind: VpcNatGateway
metadata:
  name: ovn-external-gw
  namespace: kube-system
spec:
  vpc: ovn-cluster
  subnet: vm-subnet           # <--- This triggers the Pod to get a 10.17.3.x IP
  lanIp: $NAT_GW_IP          # <--- The "Internal Door" for the VMs
  externalSubnets:
    - external-subnet
  selector:
    - "kubernetes.io/hostname: $STABLE_NODE"
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
EOF

echo "4. Applying NAT Rules..."
cat <<EOF | kubectl apply -f -
---
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

kubectl patch statefulset vpc-nat-gw-ovn-external-gw -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"vpc-nat-gw","image":"kubeovn/vpc-nat-gateway:v1.14.5"}]}}}}'

echo "Setup Complete. Monitor Gateway with: kubectl exec -it -n kube-system vpc-nat-gw-ovn-external-gw-0 -- bash"

# For some reason multi-subnet VPC is not working correctly, so need to add route rule manally

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
# 1. Allow traffic to the Service CIDR (CoreDNS Virtual IP)
kubectl exec -it -n kube-system "$LEADER_POD" -c ovn-central -- \
ovn-nbctl lr-policy-add ovn-cluster 32500 "ip4.dst == 10.96.0.0/12" allow
# 2. Allow traffic to the Pod CIDR (CoreDNS Actual Pods)
kubectl exec -it -n kube-system "$LEADER_POD" -c ovn-central -- \
ovn-nbctl lr-policy-add ovn-cluster 32500 "ip4.dst == 10.16.0.0/16" allow

kubectl exec -it -n kube-system "$LEADER_POD" -c ovn-central -- \
ovn-nbctl lr-policy-list ovn-cluster
