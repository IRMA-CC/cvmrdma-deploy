#!/usr/bin/env bash
set -u

set -x


if [[ $# -lt 2 ]]; then
  echo "$0 <VMID> <BUILD_TYPE>"
  echo "VMID: 3 or 4"
  echo "BUILD_TYPE: Release or Debug"
  exit
fi

VMID="$1"
BUILD_TYPE="$2"
BR="br-sev"


MLX5_PCI="0000:01:00.2"
IXGBE_PCI="0000:41:10.0"
#NIC_ID="0000:41:00.0"
#HOST_IFACE="enp161s0f1"
#REMOTE="4"

if [[ $VMID -ge 4 ]]; then

  vf_func=$((VMID - 2))
  if [ $vf_func -le 7 ]; then
      # Still on device 00
      device=0x0
      func=$vf_func
  else
      # Wrap to next device
      device=0x1
      func=$((vf_func - 8))
  fi

  MLX5_PCI=$(printf "0000:02:%02x.%x" $device $func)
  echo "MLX5_PCI: $MLX5_PCI"

  vf_func=$(((VMID - 4) * 2))
  if [ $vf_func -le 6 ]; then
      # Still on device 00
      device=0x10
      func=$vf_func
  else
      # Wrap to next device
      device=0x11
      func=$((vf_func - 8))
  fi

  IXGBE_PCI=$(printf "0000:85:%02x.%x" $device $func)
  echo "IXGBE_PCI: $IXGBE_PCI"
fi

#if [[ $VMID -eq 4 ]]; then
#  MLX5_PCI="0000:02:00.2"
#  IXGBE_PCI="0000:85:10.0"
  #NIC_ID="0000:85:00.0"
  #HOST_IFACE="eno2"
  #REMOTE="3"
#fi
#if [[ $VMID -eq 5 ]]; then
#  MLX5_PCI="0000:02:00.3"
#  IXGBE_PCI="0000:85:10.2"
#fi
#if [[ $VMID -eq 6 ]]; then
#  MLX5_PCI="0000:02:00.4"
#  IXGBE_PCI="0000:85:10.4"
#fi






PFDIR="/sys/bus/pci/devices/$MLX5_PCI"

MLX5_DRIVER_DIR="/sys/bus/pci/drivers/mlx5_core"
IXGBE_DRIVER_DIR="/sys/bus/pci/drivers/ixgbe"
VFIO_DRIVER_DIR="/sys/bus/pci/drivers/vfio-pci"

if [[ -d "$MLX5_DRIVER_DIR/$MLX5_PCI" ]]; then
  echo "PCI device $MLX5_PCI is bound to mlx driver. Unbinding it"

  echo "$MLX5_PCI" | tee "$MLX5_DRIVER_DIR/unbind" || { exit 1; }
fi

# Pass the PCI ID for the VFs to the VFIO driver
# OK to fail if the ID is already registered
MLX_PF_VENDOR_ID="15b3"
MLX_PF_DEVICE_ID="1018"
echo $MLX_PF_VENDOR_ID $MLX_PF_DEVICE_ID | tee /sys/bus/pci/drivers/vfio-pci/new_id || { echo "WARN: failed to register MLX's VF PCI ID"; }



if [[ ! -d "$VFIO_DRIVER_DIR/$MLX5_PCI" ]]; then
  echo "PCI device $MLX5_PCI is NOT bound to VFIO driver. Registering its ID"

  echo "$MLX5_PCI" | tee "$VFIO_DRIVER_DIR/bind" || { exit 1; }
fi

MLX5_TARGET_PCI="$MLX5_PCI"




if [[ -d "$IXGBE_DRIVER_DIR/$IXGBE_PCI" ]]; then
  echo "PCI device $IXGBE_PCI is bound to ixgbe driver. Unbinding it"

 echo "$IXGBE_PCI" | tee "$IXGBE_DRIVER_DIR/unbind" || { exit 1; }
fi

# Pass the PCI ID for the VFs to the VFIO driver
# OK to fail if the ID is already registered
#INTEL_NIC_VENDOR_ID="8086"
#INTEL_NIC_DEVICE_ID="1560"
#echo $INTEL_NIC_VENDOR_ID $INTEL_NIC_DEVICE_ID | tee /sys/bus/pci/drivers/vfio-pci/new_id || { echo "WARN: failed to register Intel NIC PCI ID"; }
#
#if [[ ! -d "$VFIO_DRIVER_DIR/$NIC_ID" ]]; then
#  echo "PCI device $NIC_ID is NOT bound to VFIO driver. Registering its ID"
#
#  echo "$NIC_ID" | tee "$VFIO_DRIVER_DIR/bind" || { exit 1; }
#fi

#TARGET_PCI_NIC="$NIC_ID"

INTEL_NIC_VENDOR_ID="8086"
INTEL_NIC_DEVICE_ID="1515"
echo $INTEL_NIC_VENDOR_ID $INTEL_NIC_DEVICE_ID | tee /sys/bus/pci/drivers/vfio-pci/new_id || { echo "WARN: failed to register Intel NIC PCI ID"; }

if [[ ! -d "$VFIO_DRIVER_DIR/$IXGBE_PCI" ]]; then
  echo "PCI device $IXGBE_PCI is NOT bound to VFIO driver. Registering its ID"

  echo "$IXGBE_PCI" | tee "$VFIO_DRIVER_DIR/bind" || { exit 1; }
fi

IXGBE_TARGET_PCI="$IXGBE_PCI"
#TARGET_PCI_NIC="$NIC_ID"



set -x

USER_HOME=$(getent passwd $SUDO_USER | cut -d: -f6)
INSTALL_DIR="$USER_HOME/leo-cvmrdma-install"
BR_DIR="$INSTALL_DIR/$BR-$BUILD_TYPE"
IMGDIR="$BR_DIR/images"
HOSTDIR="$BR_DIR/host"

EDK2_CODE="$IMGDIR/OVMF_CODE.fd"
DISK="$IMGDIR/disk.qcow2"



TMPDIR="$(mktemp -d)"
cd "$TMPDIR" || { echo "Failed to cd to $TMPDIR"; exit 1; }

THIS_DISK="$TMPDIR/disk.qcow2"

cp "$DISK" "$THIS_DISK"

# Enable ip forwarding
echo 1 | tee /proc/sys/net/ipv4/ip_forward
echo 1 | tee /proc/sys/net/ipv6/conf/all/forwarding

# Use a macvtap instead of a regular tap device
# macvtap with qemu: https://github.com/kata-containers/runtime/issues/1808
#MACVTAP_IFACE="macvtap$VMID"
#ip link add link $HOST_IFACE name "$MACVTAP_IFACE" type macvtap mode private
#ip link set up "$MACVTAP_IFACE"

#MACVTAP_ID=$(cat /sys/class/net/$MACVTAP_IFACE/ifindex | tr -s '\n' ' ')
#MACVTAP_MAC=$(cat /sys/class/net/$MACVTAP_IFACE/address | tr -s '\n' ' ')


#echo "Macvtap /dev/tap$MACVTAP_ID"
# Put the virtio-disk and virtio-net on a PCIe slot

# mount -t hugetlbfs none /mnt/huge
# 48 GiB
MEM=49152
#if [[ $VMID -ne 3 ]]; then
#  MEM=32768
#fi

MEM=12288

/home/fheinen/AMDSEV/qemu/build/qemu-system-x86_64 -accel kvm -machine q35 \
  -cpu EPYC-v4,+vaes,+avx512f \
  -smp 8,maxcpus=32 \
  -m ${MEM}M,slots=5,maxmem=$((${MEM} + 8192))M \
  -bios /home/fheinen/AMDSEV/snp-release-2025-05-10/usr/local/share/qemu/OVMF_CODE.fd \
  -no-reboot \
  -nographic \
  -device pcie-root-port,chassis=1,id=pcie.1,addr=1c.0,multifunction=on \
  -device pcie-root-port,chassis=2,id=pcie.2,addr=1c.1 \
  -device pcie-root-port,chassis=3,id=pcie.3,addr=1c.2 \
  -device pcie-root-port,chassis=4,id=pcie.4,addr=1c.3 \
  -device pcie-root-port,chassis=5,id=pcie.5,addr=1c.4 \
  -drive if=pflash,format=raw,unit=0,file=$EDK2_CODE,readonly=on \
  -drive format=qcow2,id=hda,if=none,file=$THIS_DISK \
  -device virtio-blk-pci,bus=pcie.1,drive=hda,bootindex=1,disable-legacy=on,iommu_platform=true \
  -fsdev local,path=$INSTALL_DIR,security_model=mapped-xattr,id=p9share \
  -device virtio-9p-pci,fsdev=p9share,mount_tag=p9share,bus=pcie.3 \
  -device vfio-pci,host=$MLX5_TARGET_PCI,bus=pcie.4 \
  -device vfio-pci,host=$IXGBE_TARGET_PCI,bus=pcie.5 \
  -netdev user,id=vmnic \
  -device virtio-net-pci,disable-legacy=on,iommu_platform=true,netdev=vmnic,romfile= \
  # -object memory-backend-file,id=huge,size=${MEM}M,mem-path=/mnt/huge,share=on \
  # -numa node,memdev=huge,nodeid=0 \
  # -numa node,memdev=normal_mem,nodeid=1 \
  # -object memory-backend-ram,id=normal_mem,size=$((${MEM} - 4096))M,share=on \
  # 


