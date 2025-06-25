#!/bin/bash

if ! pgrep -x opensm > /dev/null; then
  echo "ERROR: opensm is not running. Please start opensm before running this script."
  exit 1
fi

# These lists can probably be generated dynamically based on the system configuration,
# but for simplicity, they are hardcoded here.
# The address of the PFs might depend on the system configuration
# GUID values just need to be unique
pf_list=("mlx5_0" "mlx5_2")
address_list=("0000:01:00.2" "0000:02:00.2")
guid_node_list=("00:11:22:33:44:55:1:0" "00:11:22:33:44:66:1:0")
guid_port_list=("00:11:22:33:44:55:2:0" "00:11:22:33:44:66:2:0")

for ((i=0; i<${#pf_list[@]}; i++)); do
  pf="${pf_list[$i]}"
  guid_node="${guid_node_list[$i]}"
  guid_port="${guid_port_list[$i]}"
  address="${address_list[$i]}"
  device_dir="/sys/class/infiniband/$pf/device"
  if [[ -d "$device_dir" ]]; then
    # For each PF we create one VF with the specified GUIDs
    # We bring it up so it is active
    echo "PF: $pf, Node GUID: $guid_node, Port GUID: $guid_port"
    echo 1 > "$device_dir/sriov_numvfs"
    echo $guid_node > "$device_dir/sriov/0/node"
    echo $guid_port > "$device_dir/sriov/0/port"
    echo "Up" > "$device_dir/sriov/0/policy"
    echo $address > /sys/bus/pci/drivers/mlx5_core/unbind
  fi
done

