#!/usr/bin/env bash
set -u

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


SRIOV=0

if [[ $SRIOV -eq 1]]; then
  if [[ $# -lt 2 ]]; then
    echo "$0 <VMID> <PF_DEV> <VF_NUM>"
    echo "VMID: 3 or 4"
    exit
  fi

  VMID="$1"
  PF_DEV="$2"
  VF_NUM="$3"


  PF_IBDIR="/sys/class/infiniband/$PF_DEV"
  PF_DEVDIR="$PF_IBDIR/device"
  PF_PCI=$(basename $(readlink "$PF_DEVDIR"))

  echo "$PF_PCI PF $PF_DEV"

  VF_DEVDIR="$PF_DEVDIR/virtfn$VF_NUM"
  VF_CONFDIR="$PF_DEVDIR/sriov/$VF_NUM"
  VF_PCI=$(basename $(readlink "$VF_DEVDIR"))


  # Pass the PCI ID for the VFs to the VFIO driver
  # OK to fail if the ID is already registered
  MLX_VF_VENDOR_ID="15b3"
  MLX_VF_DEVICE_ID="1018"
  echo $MLX_VF_VENDOR_ID $MLX_VF_DEVICE_ID | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id || { echo "WARN: failed to register MLX's VF PCI ID"; }


  if [[ -d "$VF_DEVDIR/infiniband" ]]; then
    echo "VF is bound to host IB driver"

    VF_IBDIRS="$(find "$VF_DEVDIR/infiniband" -mindepth 1 -maxdepth 1 -type d)"
    VF_N_IBDIRS=$(wc -l <<< $VF_IBDIR)
    if [[ ! $VF_N_IBDIRS -eq 1 ]]; then
      echo "ERROR: expected only one IB device for VF, but found $VF_N_IBDIRS";
      exit 1;
    fi

    VF_IBDIR=$(head -n 1 <<< "$VF_IBDIRS")
    VF_DEV="$(basename "$VF_IBDIR")"

    echo "$VF_PCI VF $VF_DEV"

    echo "Unbinding VF from host driver"
    echo "$VF_PCI" | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind || { exit 1; }

  else
    echo "$VF_PCI VF <not bound>"
  fi

  VF_IN_VFIO_DIR="/sys/bus/pci/drivers/vfio-pci/$VF_PCI"

  if [[ ! -d "$VF_IN_VFIO_DIR" ]]; then
    echo "Binding VF to the VFIO driver"
    echo "$VF_PCI" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind || { exit 1; }
  fi



  # TODO use VMID in GUIDs
  NODE_GUID="00:11:22:33:$VMID$VMID:$VMID$VMID:1:0"
  echo "Setting Node GUID to $NODE_GUID"
  echo $NODE_GUID | sudo tee $VF_CONFDIR/node || { exit 1; }

  PORT_GUID="00:11:22:33:$VMID$VMID:$VMID$VMID:2:0"
  echo "Setting Port GUID to $PORT_GUID"
  echo $PORT_GUID | sudo tee $VF_CONFDIR/port || { exit 1; }


  TARGET_PCI="$VF_PCI"
else

  if [[ $# -lt 2 ]]; then
    echo "$0 <VMID> <PF_PCI>"
    echo "VMID: 3 or 4"
    exit
  fi

  VMID="$1"
  PF_PCI="0000:$2"

  PFDIR="/sys/bus/pci/devices/$PF_PCI"

  MLX5_DRIVER_DIR="/sys/bus/pci/drivers/mlx5_core"
  VFIO_DRIVER_DIR="/sys/bus/pci/drivers/vfio-pci"

  if [[ -d "$MLX5_DRIVER_DIR/$PF_PCI" ]]; then
    echo "PCI device $PF_PCI is bound to mlx driver. Unbinding it"

    echo "$PF_PCI" | sudo tee "$MLX5_DRIVER_DIR/unbind" || { exit 1; }
  fi

  if [[ ! -d "$VFIO_DRIVER_DIR/$PF_PCI" ]]; then
    echo "PCI device $PF_PCI is NOT bound to VFIO driver. Registering its ID"

    echo "$PF_PCI" | sudo tee "$VFIO_DRIVER_DIR/new_id" || { exit 1; }
  fi

  TARGET_PCI="$PF_PCI"
fi

INSTALL_DIR="$HOME/cvmrdma-install"
BR_DIR="$HOME/cvmrdma-install/br-qemu"
IMGDIR="$BR_DIR/images"
HOSTDIR="$BR_DIR/host"

EDK2_CODE="$HOSTDIR/share/qemu/edk2-x86_64-code.fd"
EDK2_VARS="$HOSTDIR/share/qemu/edk2-i386-vars.fd"
DISK="$IMGDIR/disk.qcow2"

HOST_IFACE="tap$VMID-cvm"

TMPDIR="$(mktemp -d)"
cd "$TMPDIR" || { echo "Failed to cd to $TMPDIR"; exit 1; }

THIS_VARS="$TMPDIR/ovmf_vars_.fd"
THIS_DISK="$TMPDIR/disk.qcow2"

cp "$EDK2_VARS" "$THIS_VARS"
cp "$DISK" "$THIS_DISK"

# Put the virtio-disk and virtio-net on a PCIe slot

sudo env LD_LIBRARY_PATH="$HOSTDIR/lib" PATH="$HOSTDIR/bin:$PATH" \
  $HOSTDIR/bin/qemu-system-x86_64 -accel kvm -machine q35 -cpu host \
  -m 4G \
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
  -netdev tap,id=hostnet0,vhost=on,ifname=$HOST_IFACE,script=no,downscript=no \
  -device virtio-net-pci,netdev=hostnet0,id=net0,bus=pcie.2 \
  -fsdev local,path=$INSTALL_DIR,security_model=mapped-xattr,id=p9share \
  -device virtio-9p-pci,fsdev=p9share,mount_tag=p9share,bus=pcie.3 \
  -device vfio-pci,host=$TARGET_PCI,bus=pcie.4