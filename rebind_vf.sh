#!/usr/bin/env bash

MLX5_PCI="0000:01:00.2"

MLX5_DRIVER_DIR="/sys/bus/pci/drivers/mlx5_core"
IXGBE_DRIVER_DIR="/sys/bus/pci/drivers/ixgbe"
VFIO_DRIVER_DIR="/sys/bus/pci/drivers/vfio-pci"

if [[ -d "$VFIO_DRIVER_DIR/$MLX5_PCI" ]]; then
  echo "PCI device $MLX5_PCI is bound to mlx driver. Unbinding it"

  echo "$MLX5_PCI" | tee "$VFIO_DRIVER_DIR/unbind" || { exit 1; }
fi


if [[ ! -d "$MLX5_DRIVER_DIR/$MLX5_PCI" ]]; then
  echo "PCI device $MLX5_PCI is NOT bound to VFIO driver. Registering its ID"

  echo "$MLX5_PCI" | tee "$MLX5_DRIVER_DIR/bind" || { exit 1; }
fi