sudo apt-get install qemu-utils
sudo apt install guestfs-tools

mkdir new_disk
cd new_disk/


#### Create disk.img from VM snapshot
kubectl exec -n default virt-launcher-vm3-pzwwc --   cat /var/run/kubevirt-ephemeral-disks/disk-data/containerdisk/disk.qcow2 > disk-overlay.qcow2
mkdir disk
docker pull lironascendra/opensuse-leap:15.6-10gb
docker create --name temp --entrypoint /bin/sh lironascendra/opensuse-leap:15.6-10gb
docker cp temp:/disk/disk.img ./base-disk.img
docker rm temp
qemu-img rebase -u -b base-disk.img -F qcow2 disk-overlay.qcow2
qemu-img convert -f qcow2 -O raw disk-overlay.qcow2 disk/disk.img


### Create disk.img from vmdk
qemu-img convert -f vmdk -O raw disk-overlay.vmdk disk/disk.img

# Then disable swap on the raw image
virt-customize -a disk/disk.img \
  --run-command 'swapoff -a' \
  --run-command 'sed -i "/swap/d" /etc/fstab' \
  --run-command 'systemctl mask swap.target' \
  --selinux-relabel
 
### Build and push the container image
cat > Dockerfile <<'EOF'
# We use 'scratch' because the image only needs to serve as a
# data transport for the virtual disk file.
FROM scratch
# KubeVirt's virt-launcher specifically looks in the /disk directory
# for a file named disk.img, disk.qcow2, or disk.raw.
# This copies your customized disk into the container.
COPY disk/disk.img /disk/disk.img
# It is a best practice to set the user to 107 (qemu).
# This ensures the KubeVirt launcher has the correct permissions
# to read the disk file without needing to run as root.
USER 107
# No CMD or ENTRYPOINT is needed because this container is never
# "executed" as a process; it is only mounted as a volume.
EOF

docker build -t lironascendra/opensuse-leap:15.6-10gb .
docker push lironascendra/opensuse-leap:15.6-10gb

