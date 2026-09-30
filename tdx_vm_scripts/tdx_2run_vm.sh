#!/usr/bin/env bash
set -u
set -x


if [[ $# -lt 1 ]]; then
  echo "$0 <VMID> [--no-taskset]"
  echo "VMID: 0 to 3"
  echo "Optional flags:"
  echo "  --no-taskset    Disable CPU pinning with taskset"
  exit
fi

VMID="$1"
BUILD_TYPE="Release"
BR="br-sev"
USE_TASKSET=true

# Check for --no-taskset flag
for arg in "$@"; do
  if [[ "$arg" == "--no-taskset" ]]; then
    USE_TASKSET=false
  fi
done

if [[ $VMID -ge 2 ]]; then

  echo "VMID >=2 to large, exiting"
  exit 1
fi

HOSTNAME=$(hostname)

# Default value
DEFAULT_DIR=""


case "$HOSTNAME" in
    TurboDieselXylophone)
      DEFAULT_DIR="/home/fheinen/"
    ;;
    sectrs-tripledamagexray)
      DEFAULT_DIR="/home/ubuntu/Documents/"
      VMID=1
    ;;
    *)
        exit 1
        ;;
esac

TMPDIR="$DEFAULT_DIR/cvmrdma_vm_tmpdir_$VMID"
mkdir -p "$TMPDIR"

## adjust PCI addresses based on VMID
# VMID_ADD_2=$((VMID + 2))
# MLX5_PCI=$(printf "0000:17:00.%x" $VMID_ADD_2)
# echo "MLX5_PCI: $MLX5_PCI"

# MLX5_ETH_PCI=$(printf "0000:17:02.%x" $VMID_ADD_2)
# echo "MLX5_ETH_PCI: $MLX5_ETH_PCI"

# VMID_TIMES_2=$((VMID * 2))
# IXGBE_PCI=$(printf "0000:c7:10.%x" $VMID_TIMES_2)
# echo "IXGBE_PCI: $IXGBE_PCI"

MLX5_PCI="0000:17:00.2"
MLX5_ETH_PCI="0000:17:02.2"
IXGBE_PCI="0000:43:10.0"

#if [[ $VMID -eq 0 ]]; then
#  MLX5_PCI="0000:c7:00.2"
#  MLX5_ETH_PCI="0000:c7:02.2"
#  IXGBE_PCI="0000:71:10.2"
#fi


## unbind devices from their current drivers and bind to vfio-pci
PFDIR="/sys/bus/pci/devices/$MLX5_PCI"

MLX5_DRIVER_DIR="/sys/bus/pci/drivers/mlx5_core"
IXGBEVF_DRIVER_DIR="/sys/bus/pci/drivers/ixgbevf"
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

if [[ -d "$MLX5_DRIVER_DIR/$MLX5_ETH_PCI" ]]; then
  echo "PCI device $MLX5_ETH_PCI is bound to mlx driver. Unbinding it"

  echo "$MLX5_ETH_PCI" | tee "$MLX5_DRIVER_DIR/unbind" || { exit 1; }
fi
MLX_PF_VENDOR_ID="15b3"
MLX_PF_DEVICE_ID="1018"
echo $MLX_PF_VENDOR_ID $MLX_PF_DEVICE_ID | tee /sys/bus/pci/drivers/vfio-pci/new_id || { echo "WARN: failed to register MLX's VF PCI ID"; }

if [[ ! -d "$VFIO_DRIVER_DIR/$MLX5_ETH_PCI" ]]; then
  echo "PCI device $MLX5_ETH_PCI is NOT bound to VFIO driver. Registering its ID"

  echo "$MLX5_ETH_PCI" | tee "$VFIO_DRIVER_DIR/bind" || { exit 1; }
fi
MLX5_ETH_TARGET_PCI="$MLX5_ETH_PCI"

if [[ -d "$IXGBEVF_DRIVER_DIR/$IXGBE_PCI" ]]; then
  echo "PCI device $IXGBE_PCI is bound to ixgbe driver. Unbinding it"
 
 echo "$IXGBE_PCI" | tee "$IXGBEVF_DRIVER_DIR/unbind" || { exit 1; }
fi

INTEL_NIC_VENDOR_ID="8086"
INTEL_NIC_DEVICE_ID="1515"
echo $INTEL_NIC_VENDOR_ID $INTEL_NIC_DEVICE_ID | tee /sys/bus/pci/drivers/vfio-pci/new_id || { echo "WARN: failed to register Intel NIC PCI ID"; }

if [[ ! -d "$VFIO_DRIVER_DIR/$IXGBE_PCI" ]]; then
  echo "PCI device $IXGBE_PCI is NOT bound to VFIO driver. Registering its ID"

  echo "$IXGBE_PCI" | tee "$VFIO_DRIVER_DIR/bind" || { exit 1; }
fi

IXGBE_TARGET_PCI="$IXGBE_PCI"



set -x

# USER_HOME=$(getent passwd $SUDO_USER | cut -d: -f6)
INSTALL_DIR="$DEFAULT_DIR/leo-cvmrdma-install"
BR_DIR="$INSTALL_DIR/$BR-$BUILD_TYPE"
IMGDIR="$BR_DIR/images"

TDX_DIR="$DEFAULT_DIR/tdx_data"
TDX_MOUNT_DIR="$DEFAULT_DIR/leo-cvmrdma-src"

DISK="$TDX_DIR/noble-server-cloudimg-amd64_custom_kernel_v9_autostart.img"
SEED="$TDX_DIR/seed-root-autologin.img"

BOOT_MAIN_DISK=0

if [[ $BOOT_MAIN_DISK -eq 1 ]]; then
  THIS_DISK="$TDX_DIR/noble-server-cloudimg-amd64_custom_kernel_v9_autostart.img"
  THIS_SEED="$TDX_DIR/seed-root-autologin.img"
else 
  mkdir -p "VMID_tmp_$VMID"
  THIS_DISK="VMID_tmp_$VMID/noble-server-cloudimg-amd64_custom_kernel_v9_autostart.img"
  THIS_SEED="VMID_tmp_$VMID/seed-root-autologin.img"

  cp "$DISK" "$THIS_DISK"
  cp "$SEED" "$THIS_SEED"
fi

# THIS_DISK="$TMPDIR/disk.qcow2"

# cp "$DISK" "$THIS_DISK"

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
#mount -t hugetlbfs none /mnt/huge
# enable 2MB THP pages, see https://github.com/AMDESE/AMDSEV/issues/225
#echo 1 >/sys/module/kvm/parameters/gmem_2m_enabled

# MEM=49152 # with 32gb cma, not sure what for?
# MEM=32768 # works with gam and 20gb cma
#if [[ $VMID -ne 3 ]]; then
#  MEM=24336 # works with gam and 20gb cma
#fi

# MEM=16384 # works for most default experiements with 12gb cma
MEM=32768

# Add SEV diagnostic checks
echo "=== SEV Diagnostics before launching VM $VMID ==="
echo "Current running QEMU processes:"
ps aux | grep qemu-system-x86_64 | grep -v grep | wc -l

echo "Memory usage:"
free -h | grep Mem

echo "Available memory for new VM (need ${MEM}M):"
available_mb=$(free -m | awk '/^Mem:/ {print $7}')
echo "Available: ${available_mb}M"
if [ "$available_mb" -lt "$MEM" ]; then
    echo "WARNING: Insufficient memory! Need ${MEM}M, have ${available_mb}M"
fi

echo "VFIO devices in use:"
ls /sys/bus/pci/drivers/vfio-pci/ | grep "0000:" | wc -l

echo "Checking PCI device availability:"
echo "MLX5 device $MLX5_TARGET_PCI exists: $([ -d "/sys/bus/pci/devices/$MLX5_TARGET_PCI" ] && echo "YES" || echo "NO")"
echo "IXGBE device $IXGBE_TARGET_PCI exists: $([ -d "/sys/bus/pci/devices/$IXGBE_TARGET_PCI" ] && echo "YES" || echo "NO")"

echo "=== End Diagnostics ==="



echo "Starting QEMU with TDX for VM $VMID..."
echo "Using MLX5: $MLX5_TARGET_PCI, IXGBE: $IXGBE_TARGET_PCI"

# Capture QEMU exit code and potential error
set +e  # Don't exit on error

# /usr/bin/qemu-system-x86_64 \

TASKSET_CMD=""
$TASKSET_CMD \
/usr/bin/qemu-system-x86_64 \
  -accel kvm \
  -cpu host \
  -object memory-backend-ram,id=mem0,size=${MEM}M \
  -machine q35,kernel_irqchip=split,memory-backend=mem0 \
  -m ${MEM}M \
  -smp 2 \
  -bios /usr/share/ovmf/OVMF.fd \
  -nographic \
  -serial mon:stdio \
  -nodefaults \
  -vga none \
  -netdev user,id=vmnic \
  -device virtio-net-pci,netdev=vmnic \
  -drive file=$THIS_DISK,if=none,id=virtio-disk0,format=qcow2 \
  -device virtio-blk-pci,drive=virtio-disk0 \
  -drive file=$THIS_SEED,if=none,id=seed-disk,format=raw \
  -device virtio-blk-pci,drive=seed-disk \
  -device virtio-serial \
  -device pcie-root-port,chassis=1,id=pcie.1,addr=1c.0,multifunction=on \
  -device pcie-root-port,chassis=2,id=pcie.2,addr=1c.1 \
  -device pcie-root-port,chassis=3,id=pcie.3,addr=1c.2 \
  -device pcie-root-port,chassis=4,id=pcie.4,addr=1c.3 \
  -device pcie-root-port,chassis=5,id=pcie.5,addr=1c.4 \
  -device pcie-root-port,chassis=6,id=pcie.6,addr=1c.5 \
  -fsdev local,path=$TDX_MOUNT_DIR,security_model=passthrough,id=p9share \
  -device virtio-9p-pci,fsdev=p9share,mount_tag=p9share,bus=pcie.3 \
  -device vfio-pci,host=$MLX5_TARGET_PCI,bus=pcie.4 \
  -device vfio-pci,host=$IXGBE_TARGET_PCI,bus=pcie.5 \
  -device vfio-pci,host=$MLX5_ETH_TARGET_PCI,bus=pcie.6 \

qemu_exit_code=$?
set -e  # Re-enable exit on error

echo "QEMU exited with code: $qemu_exit_code"
if [ $qemu_exit_code -ne 0 ]; then
    echo "QEMU failed! Checking system state..."
    echo "Recent kernel messages:"
    dmesg | tail -20
    echo "Memory after failure:"
    free -h
    echo "Running QEMU processes:"
    ps aux | grep qemu-system-x86_64 | grep -v grep
fi

  # -object memory-backend-file,id=huge,size=4G,mem-path=/mnt/huge,share=on \
  # -numa node,memdev=huge,nodeid=0 \
  # -numa node,memdev=ram1,nodeid=1 \

#  -netdev tap,id=hostnet0,vhost=on,ifname=$MACVTAP_IFACE,script=no,downscript=no \

#   sudo mount -t 9p -o trans=virtio,version=9p2000.L p9share /home/ubuntu/mnt
