#!/bin/bash

if ! pgrep -x opensm > /dev/null; then
    echo "opensm not running, starting it..."
    opensm --log_limit 32 &
else
    echo "opensm is already running."
fi

# These lists can probably be generated dynamically based on the system configuration,
# but for simplicity, they are hardcoded here.
# The address of the PFs might depend on the system configuration
# GUID values just need to be unique
pf_list=("mlx5_0" "mlx5_2")
num_vfs_per_pf=2

for ((i=0; i<${#pf_list[@]}; i++)); do
  pf="${pf_list[$i]}"
  device_dir="/sys/class/infiniband/$pf/device"
  if [[ -d "$device_dir" ]]; then
    # For each PF we create one VF with the specified GUIDs
    # We bring it up so it is active
    echo 0 > "$device_dir/sriov_numvfs"  # Disable VFs first
    echo $num_vfs_per_pf > "$device_dir/sriov_numvfs"

    for ((vf=0; vf<num_vfs_per_pf; vf++)); do
        echo "Configuring VF $vf for PF $pf"

        guid_node=$(printf "00:00:00:00:%02x:%02x:01:00" $((i+1)) $((vf+2)))
        guid_port=$(printf "00:00:00:00:%02x:%02x:02:00" $((i+1)) $((vf+2)))
        # this relies on the addresses of the devices, if the NICs are plugged into different slots,
        # the addresses will be different, this might need to be adjusted
        # in our case the first lsots of the NICs have addresses 0000:01:00.0 and 0000:02:00.0
        # the second slots are 0000:01:00.1 and 0000:02:00.1#
        # and VFs start from 0000:01:00.2 and 0000:02:00.2
        address=$(printf "0000:%02x:00.%x" $((i+1)) $((vf+2)))

        echo "GUID Node: $guid_node"
        echo "GUID Port: $guid_port"

        # unbind the VF from the mlx5_core driver first, otherwise we cannot set the GUIDs
        echo $address > /sys/bus/pci/drivers/mlx5_core/unbind
        echo $guid_node > "$device_dir/sriov/$vf/node"
        echo $guid_port > "$device_dir/sriov/$vf/port"
        # IT is important to set the policy to "Up" after setting the GUIDs
        # otherwise the GUIDs will reamin in the down state
        echo "Up" > "$device_dir/sriov/$vf/policy"

        # Read back the values
        node_val=$(sudo cat "$device_dir/sriov/$vf/node")
        port_val=$(sudo cat "$device_dir/sriov/$vf/port")

        # Compare and warn if different
        if [[ "$node_val" != "$guid_node" ]]; then
            echo "WARNING: node GUID mismatch for $pf VF $vf (set: $guid_node, read: $node_val)"
        fi
        if [[ "$port_val" != "$guid_port" ]]; then
            echo "WARNING: port GUID mismatch for $pf VF $vf (set: $guid_port, read: $port_val)"
        fi

        # Bind the VF to the mlx5_core driver afterwards
        # this is not necessary if we start vms with the vfs
        # but the VM script will unbind them anyway, so we bind them to make the script more universal
        echo $address > /sys/bus/pci/drivers/mlx5_core/bind
    done
  fi
done

