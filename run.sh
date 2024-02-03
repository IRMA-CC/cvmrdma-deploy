#!/usr/bin/env bash
set -u

if [[ $# -lt 2 ]]; then
  echo "$0 <VMID> <BUILD_TYPE>"
  echo "VMID: 3 or 4"
  echo "BUILD_TYPE: Release or Debug"
  exit
fi

VMID="$1"
BUILD_TYPE="$2"
BR="br-sev"


PF_PCI="0000:49:00.0"
HOST_IFACE="enp161s0f1"
REMOTE="4"
if [[ $VMID -eq 4 ]]; then
  PF_PCI="0000:4f:00.0"
  HOST_IFACE="eno2"
  REMOTE="3"
fi



PFDIR="/sys/bus/pci/devices/$PF_PCI"

MLX5_DRIVER_DIR="/sys/bus/pci/drivers/mlx5_core"
VFIO_DRIVER_DIR="/sys/bus/pci/drivers/vfio-pci"

if [[ -d "$MLX5_DRIVER_DIR/$PF_PCI" ]]; then
  echo "PCI device $PF_PCI is bound to mlx driver. Unbinding it"

  echo "$PF_PCI" | tee "$MLX5_DRIVER_DIR/unbind" || { exit 1; }
fi


# Pass the PCI ID for the VFs to the VFIO driver
# OK to fail if the ID is already registered
MLX_PF_VENDOR_ID="15b3"
MLX_PF_DEVICE_ID="1017"
echo $MLX_PF_VENDOR_ID $MLX_PF_DEVICE_ID | tee /sys/bus/pci/drivers/vfio-pci/new_id || { echo "WARN: failed to register MLX's VF PCI ID"; }


if [[ ! -d "$VFIO_DRIVER_DIR/$PF_PCI" ]]; then
  echo "PCI device $PF_PCI is NOT bound to VFIO driver. Registering its ID"

  echo "$PF_PCI" | tee "$VFIO_DRIVER_DIR/bind" || { exit 1; }
fi

TARGET_PCI="$PF_PCI"

USER_HOME=$(getent passwd $SUDO_USER | cut -d: -f6)
INSTALL_DIR="$USER_HOME/cvmrdma-install"
BR_DIR="$INSTALL_DIR/$BR-$BUILD_TYPE"
IMGDIR="$BR_DIR/images"
HOSTDIR="$BR_DIR/host"

EDK2_CODE="$HOSTDIR/share/qemu/edk2-x86_64-code.fd"
EDK2_VARS="$HOSTDIR/share/qemu/edk2-i386-vars.fd"
DISK="$IMGDIR/disk.qcow2"

TMPDIR="$(mktemp -d)"
cd "$TMPDIR" || { echo "Failed to cd to $TMPDIR"; exit 1; }

THIS_VARS="$TMPDIR/ovmf_vars_.fd"
THIS_DISK="$TMPDIR/disk.qcow2"

cp "$EDK2_VARS" "$THIS_VARS"
cp "$DISK" "$THIS_DISK"

# Enable ip forwarding
echo 1 | tee /proc/sys/net/ipv4/ip_forward
echo 1 | tee /proc/sys/net/ipv6/conf/all/forwarding


# Use a macvtap instead of a regular tap device
# macvtap with qemu: https://github.com/kata-containers/runtime/issues/1808
MACVTAP_IFACE="macvtap$VMID"
ip link add link $HOST_IFACE name "$MACVTAP_IFACE" type macvtap mode private
ip link set up "$MACVTAP_IFACE"

MACVTAP_ID=$(cat /sys/class/net/$MACVTAP_IFACE/ifindex | tr -s '\n' ' ')
MACVTAP_MAC=$(cat /sys/class/net/$MACVTAP_IFACE/address | tr -s '\n' ' ')


echo "Macvtap /dev/tap$MACVTAP_ID"
# Put the virtio-disk and virtio-net on a PCIe slot


# Put the virtio-disk and virtio-net on a PCIe slot

env LD_LIBRARY_PATH="$HOSTDIR/lib" PATH="$HOSTDIR/bin:$PATH" \
  $HOSTDIR/bin/qemu-system-x86_64 -accel kvm -machine q35 -cpu host \
  -m 16G \
  -nographic \
  -display none \
  -device pcie-root-port,chassis=1,id=pcie.1,addr=1c.0,multifunction=on \
  -device pcie-root-port,chassis=2,id=pcie.2,addr=1c.1 \
  -device pcie-root-port,chassis=3,id=pcie.3,addr=1c.2 \
  -device pcie-root-port,chassis=4,id=pcie.4,addr=1c.3 \
  -drive if=pflash,format=raw,unit=0,file=$EDK2_CODE,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=$THIS_VARS \
  -drive format=qcow2,id=hda,if=none,file=$THIS_DISK \
  -device virtio-blk-pci,scsi=off,bus=pcie.1,drive=hda,bootindex=1 \
  -netdev tap,fd=3,id=hostnet0,vhost=on,vhostfd=4 \
  -device virtio-net-pci,netdev=hostnet0,id=net0,bus=pcie.2,mac=$MACVTAP_MAC \
  -fsdev local,path=$INSTALL_DIR,security_model=mapped-xattr,id=p9share \
  -device virtio-9p-pci,fsdev=p9share,mount_tag=p9share,bus=pcie.3 \
  -device vfio-pci,host=$TARGET_PCI,bus=pcie.4 \
  3<>/dev/tap$MACVTAP_ID 4<>/dev/vhost-net
