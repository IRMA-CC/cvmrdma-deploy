# this script binds the mlx5 devices back to mlx5_core driver
# this is useful when debugging on the host and you want to use the mlx5 devices
for p in 0000:01:00.0 0000:01:00.1 0000:01:00.2 0000:02:00.0 0000:02:00.1 0000:02:00.2; do
    echo $p | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind | sudo tee /sys/bus/pci/drivers/mlx5_core/bind;
done
