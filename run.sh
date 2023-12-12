#!/usr/bin/env bash
set -xu

# Requires a tap device called tap0-cvm to be already setup and connected to a bridge
# (or a tap device with host routing)

# Requires the rdmam-mux to be running
# 1. disable the CM kernel modules
# $ sudo modprobe -r ib_ipoib
# $ sudo modprobe -r ib_cm
# $ sudo modprobe -r rdma_ucm
# $ sudo modprobe -r rdma_cm
# 2. start the daemon
# $ sudo rdmacm-mux -d mlx5_0


BR_DIR="$HOME/cvmrdma-install/br-cvm"
IMGDIR="$BR_DIR/images"
HOSTDIR="$BR_DIR/host"

EDK2_CODE="$HOSTDIR/share/qemu/edk2-x86_64-code.fd"
EDK2_VARS="$HOSTDIR/share/qemu/edk2-i386-vars.fd"


cd "$IMGDIR" || { echo "Failed to cd to $IMGDIR"; exit 1; }

IBDEV="mlx5_0"
IBPORT="1"
MAD_CHARDEV="/var/run/rdmacm-mux-$IBDEV-$IBPORT"

HOST_IFACE="tap0-cvm"

cp "$EDK2_VARS" ./ovmf_vars.fd

# Put the virtio-disk on a PCIe slot
# Put the VMXNET3 device and the PVRDMA device on the same slot with
#    function 0: VMXNET3
#    function 1: PVRDMA
# (this is necessary s.t. PVRDMA finds the VMXNET3 device)




sudo env LD_LIBRARY_PATH="$HOSTDIR/lib" PATH="$HOSTDIR/bin:$PATH" \
  $HOSTDIR/bin/qemu-system-x86_64 -accel kvm -machine q35 -cpu host \
  -m 2G \
  -nographic \
  -display none \
  -device pcie-root-port,chassis=1,id=pcie.1,addr=1c.0,multifunction=on \
  -drive if=pflash,format=raw,unit=0,file=$EDK2_CODE,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=ovmf_vars.fd \
  -drive format=qcow2,id=hda,if=none,file=disk.qcow2 \
  -device virtio-blk-pci,scsi=off,bus=pcie.1,addr=0x0,drive=hda,bootindex=1 \
  -netdev tap,id=hostnet0,vhost=on,ifname=tap0-cvm,script=no,downscript=no \
  -device vmxnet3,netdev=hostnet0,mac=00:11:22:33:44:55,id=net0,addr=10.0,multifunction=on \
  -object memory-backend-ram,id=mb1,size=2G,share=on \
  -numa node,memdev=mb1 \
  -chardev socket,path=$MAD_CHARDEV,id=mads \
  -device pvrdma,ibdev=$IBDEV,ibport=1,netdev=$HOST_IFACE,mad-chardev=mads,addr=10.1