#!/usr/bin/env bash
set -u

get_cbitpos() {
	modprobe cpuid
	#
	# Get C-bit position directly from the hardware
	#   Reads of /dev/cpu/x/cpuid have to be 16 bytes in size
	#     and the seek position represents the CPUID function
	#     to read.
	#   The skip parameter of DD skips ibs-sized blocks, so
	#     can't directly go to 0x8000001f function (since it
	#     is not a multiple of 16). So just start at 0x80000000
	#     function and read 32 functions to get to 0x8000001f
	#   To get to EBX, which contains the C-bit position, skip
	#     the first 4 bytes (EAX) and then convert 4 bytes.
	#

	EBX=$(dd if=/dev/cpu/0/cpuid ibs=16 count=32 skip=134217728 | tail -c 16 | od -An -t u4 -j 4 -N 4 | sed -re 's|^ *||')
	CBITPOS=$((EBX & 0x3f))
}


set -x


if [[ $# -lt 2 ]]; then
  echo "$0 <VMID> <BUILD_TYPE>"
  echo "VMID: 3 or 4"
  echo "BUILD_TYPE: Release or Debug"
  exit
fi

VMID="$1"
BUILD_TYPE="$2"

PF_PCI="0000:01:00.0"
NIC_ID="0000:41:00.0"
HOST_IFACE="enp161s0f1"
REMOTE="4"
if [[ $VMID -eq 4 ]]; then
  PF_PCI="0000:02:00.0"
  NIC_ID="0000:85:00.0"
  HOST_IFACE="eno2"
  REMOTE="3"
fi


PFDIR="/sys/bus/pci/devices/$PF_PCI"

MLX5_DRIVER_DIR="/sys/bus/pci/drivers/mlx5_core"
IXGBE_DRIVER_DIR="/sys/bus/pci/drivers/ixgbe"
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




if [[ -d "$IXGBE_DRIVER_DIR/$NIC_ID" ]]; then
  echo "PCI device $NIC_ID is bound to ixgbe driver. Unbinding it"

  echo "$NIC_ID" | tee "$IXGBE_DRIVER_DIR/unbind" || { exit 1; }
fi

# Pass the PCI ID for the VFs to the VFIO driver
# OK to fail if the ID is already registered
INTEL_NIC_VENDOR_ID="8086"
INTEL_NIC_DEVICE_ID="1560"
echo $INTEL_NIC_VENDOR_ID $INTEL_NIC_DEVICE_ID | tee /sys/bus/pci/drivers/vfio-pci/new_id || { echo "WARN: failed to register Intel NIC PCI ID"; }

if [[ ! -d "$VFIO_DRIVER_DIR/$NIC_ID" ]]; then
  echo "PCI device $NIC_ID is NOT bound to VFIO driver. Registering its ID"

  echo "$NIC_ID" | tee "$VFIO_DRIVER_DIR/bind" || { exit 1; }
fi

TARGET_PCI_NIC="$NIC_ID"



set -x

USER_HOME=$(getent passwd $SUDO_USER | cut -d: -f6)
INSTALL_DIR="$USER_HOME/cvmrdma-install"
BR_DIR="$INSTALL_DIR/br-sev-$BUILD_TYPE"
IMGDIR="$BR_DIR/images"
HOSTDIR="$BR_DIR/host"

EDK2_CODE="/home/lcohnen/AMDSEV/usr/local/share/qemu/OVMF_CODE.fd"
DISK="$IMGDIR/disk.qcow2"

# 48 GiB
MEM=49152

TMPDIR="$(mktemp -d)"
cd "$TMPDIR" || { echo "Failed to cd to $TMPDIR"; exit 1; }

THIS_DISK="$TMPDIR/disk.qcow2"

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
mount -t hugetlbfs none /mnt/huge
# enable 2MB THP pages, see https://github.com/AMDESE/AMDSEV/issues/225
echo 1 >/sys/module/kvm/parameters/gmem_2m_enabled


get_cbitpos
/home/lcohnen/AMDSEV/usr/local/bin/qemu-system-x86_64 -accel kvm -machine q35 \
  -cpu EPYC-v4,+vaes,+avx512f \
  -smp 4,maxcpus=255 \
  -m ${MEM}M,slots=5,maxmem=$((${MEM} + 8192))M \
  -machine memory-encryption=sev0,vmport=off \
  -object memory-backend-memfd,id=ram1,size=$((${MEM} + 0))M,share=true,prealloc=false \
  -machine memory-backend=ram1 \
  -object sev-snp-guest,id=sev0,cbitpos=${CBITPOS},reduced-phys-bits=1 \
  -bios /home/lcohnen/AMDSEV/usr/local/share/qemu/OVMF.fd \
  -no-reboot \
  -nographic \
  -device pcie-root-port,chassis=1,id=pcie.1,addr=1c.0,multifunction=on \
  -device pcie-root-port,chassis=2,id=pcie.2,addr=1c.1 \
  -device pcie-root-port,chassis=3,id=pcie.3,addr=1c.2 \
  -device pcie-root-port,chassis=4,id=pcie.4,addr=1c.3 \
  -device pcie-root-port,chassis=5,id=pcie.5,addr=1c.4 \
  -drive format=qcow2,id=hda,if=none,file=$THIS_DISK \
  -device virtio-blk-pci,bus=pcie.1,drive=hda,bootindex=1,disable-legacy=on,iommu_platform=true \
  -fsdev local,path=$INSTALL_DIR,security_model=mapped-xattr,id=p9share \
  -device virtio-9p-pci,fsdev=p9share,mount_tag=p9share,bus=pcie.3 \
  -device vfio-pci,host=$TARGET_PCI,bus=pcie.4 \
  -device vfio-pci,host=$TARGET_PCI_NIC,bus=pcie.5 \
  -netdev user,id=vmnic \
  -device virtio-net-pci,disable-legacy=on,iommu_platform=true,netdev=vmnic,romfile= \

  # -object memory-backend-file,id=huge,size=4G,mem-path=/mnt/huge,share=on \
  # -numa node,memdev=huge,nodeid=0 \
  # -numa node,memdev=ram1,nodeid=1 \

#  -netdev tap,id=hostnet0,vhost=on,ifname=$MACVTAP_IFACE,script=no,downscript=no \
