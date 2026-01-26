# Cluster Checklist

## Setup Cluster
Use `install_k8s_node.sh` to install on all nodes.

## Environment
```bash
export GHCR_TOKEN=<your_token>
```

## Deploy Tyr
```bash
kubectl create namespace tyr-system
kubectl create secret docker-registry ghcr-secret   --docker-server=ghcr.io   --docker-username=ascendra-networks   --docker-password="$GHCR_TOKEN"   --namespace tyr-system
# 2. Login to Helm OCI registry
echo "$GHCR_TOKEN" | helm registry login ghcr.io -u ascendra-networks --password-stdin
# 3. Install directly from OCI registry
helm install tyr oci://ghcr.io/ascendra-networks/charts/tyr   --version 1.0.3   --namespace tyr-system   --create-namespace   --set github.createSecret=true   --set github.token="$GHCR_TOKEN"   --set imagePullSecrets[0].name=ghcr-secret
# 4. Apply CR
kubectl apply -f - <<EOF
apiVersion: infra.ascendra.cloud/v1alpha1
kind: InfraManager
metadata:
  labels:
    app.kubernetes.io/name: tyr
    app.kubernetes.io/managed-by: kustomize
  name: inframanager-sample
  namespace: tyr-system
spec:
  kubeOvn:
    version: "v1.14.5"
  kubeVirt:
    imageTag: "v1.7.0-ascendra.0"
    imagePullPolicy: Always
    cpuAllocationRatio: 8
    githubTokenRef:
      name: tyr-github
      key: token
    kubeVirtSpec:
      configuration:
        # Adding the requested migration settings
        migrations:
          autoConverge: true
          autoConvergeInitial: 90
          autoConvergeIncrement: 50
          # SAFE ALTERNATIVE TO POST-COPY:
          # This allows the controller to pause the VM to force completion
          # when convergence isn't happening naturally.
          allowWorkloadDisruption: true
          allowPostCopy: false
          # REMOVE NETWORK BOTTLENECKS:
          # 0 means unlimited bandwidth.
          bandwidthPerMigration: 0
          # CONTROL THE TIMEOUT:
          # Seconds per GiB before the "Pause" strategy is triggered.
          completionTimeoutPerGiB: 30
EOF
```

## Deploy Metrics
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/args/-",
    "value": "--kubelet-insecure-tls"
  }
]'
kubectl wait --for=condition=available --timeout=60s deployment/metrics-server -n kube-system
```

## Deploy Dashboard
1. Create monitoring namespace
```bash
kubectl create namespace monitoring
```
2. Create github secret for monitoring namespace
```bash
kubectl create secret docker-registry ghcr-secret --docker-server=ghcr.io --docker-username=ascendra-networks   --docker-password="$GHCR_TOKEN" --namespace monitoring
```
3. make sure rancher local is running -
```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.34/deploy/local-path-storage.yaml
```
4. patch it -
```bash
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```
5. Deploy dashbaord -
```bash
helm install management-dashboard   oci://ghcr.io/ascendra-networks/charts/management-dashboard   --version 1.4.4 --namespace monitoring --create-namespace --set github.createSecret=true --set github.token="$GHCR_TOKEN" --set imagePullSecrets[0].name=ghcr-secret
```

## Persistent Storage
Longhorn with Local Disks (https://claude.ai/share/e5eb215b-ea38-430b-99dc-85fc019cabb9?)

## Generate VMs
Use `generate-vms.sh` as baseline for VMs yaml.
