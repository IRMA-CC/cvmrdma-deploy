#!/usr/bin/env bash
set -u

# Requires a tap device called tap0-cvm to be already setup and connected to a bridge
# (or a tap device with host routing)



if [[ $# -lt 1 ]]; then
  echo "$0 <VMID>"
  echo "VMID: 3 or 4"
  exit
fi

VMID="$1"


get_cbitpos() {
	sudo modprobe cpuid
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

	EBX=$(sudo dd if=/dev/cpu/0/cpuid ibs=16 count=32 skip=134217728 | tail -c 16 | od -An -t u4 -j 4 -N 4 | sed -re 's|^ *||')
	CBITPOS=$((EBX & 0x3f))
}


set -x



if [[ $# -lt 1 ]]; then
  echo "$0 <VMID>"
  echo "VMID: 3 or 4"
  exit
fi

VMID="$1"

set -x


INSTALL_DIR="$HOME/cvmrdma-install"
BR_DIR="$INSTALL_DIR/br-sev"
IMGDIR="$BR_DIR/images"
HOSTDIR="$BR_DIR/host"

EDK2_CODE="$IMGDIR/OVMF_CODE.fd"
EDK2_VARS="$IMGDIR/OVMF_VARS.fd"
DISK="$IMGDIR/disk.qcow2"

MEM=2048
DISCARD="none"
HOST_IFACE="tap$VMID-cvm"

TMPDIR="$(mktemp -d)"
cd "$TMPDIR" || { echo "Failed to cd to $TMPDIR"; exit 1; }

THIS_VARS="$TMPDIR/ovmf_vars_.fd"
THIS_DISK="$TMPDIR/disk.qcow2"

cp "$EDK2_VARS" "$THIS_VARS"
cp "$DISK" "$THIS_DISK"

# Put the virtio-disk and virtio-net on a PCIe slot

get_cbitpos
sudo env LD_LIBRARY_PATH="$HOSTDIR/lib" PATH="$HOSTDIR/bin:$PATH" \
  $HOSTDIR/bin/qemu-system-x86_64 -accel kvm -machine q35 -cpu EPYC-v4 \
  -smp 4,maxcpus=255 \
  -m ${MEM}M,slots=5,maxmem=$((${MEM} + 8192))M \
  -machine memory-encryption=sev0,vmport=off \
  -object memory-backend-memfd-private,id=ram1,size=${MEM}M,share=true \
  -object sev-snp-guest,id=sev0,cbitpos=${CBITPOS},reduced-phys-bits=1,discard=${DISCARD} \
  -machine memory-backend=ram1,kvm-type=protected \
  -no-reboot \
  -nographic \
  -device pcie-root-port,chassis=1,id=pcie.1,addr=1c.0,multifunction=on \
  -device pcie-root-port,chassis=2,id=pcie.2,addr=1c.1 \
  -device pcie-root-port,chassis=3,id=pcie.3,addr=1c.2 \
  -device pcie-root-port,chassis=4,id=pcie.4,addr=1c.3 \
  -drive if=pflash,format=raw,unit=0,file=$EDK2_CODE,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=$THIS_VARS \
  -drive format=qcow2,id=hda,if=none,file=$THIS_DISK \
  -device virtio-blk-pci,scsi=off,bus=pcie.1,drive=hda,bootindex=1,disable-legacy=on,iommu_platform=true \
  -netdev tap,id=hostnet0,vhost=on,ifname=$HOST_IFACE,script=no,downscript=no \
  -device virtio-net-pci,netdev=hostnet0,id=net0,bus=pcie.2 \
  -fsdev local,path=$INSTALL_DIR,security_model=mapped-xattr,id=p9share \
  -device virtio-9p-pci,fsdev=p9share,mount_tag=p9share,bus=pcie.3