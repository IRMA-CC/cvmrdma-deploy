#!/bin/bash

modprobe vfio-pci
mst start
modprobe mst-pci
mst status

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
pf_list_mlx5=("mlx5_0" "mlx5_2")
pf_list_ixgbe=("enp65s0" "enp133s0")
num_vfs_per_pf=8

#num_vms=4

#HUGE_PAGE_MEM=$((24576 * num_vms))

#echo $((HUGE_PAGE_MEM/2)) > /proc/sys/vm/nr_hugepages  # For 2MB pages, MEM in MB
#if [ -e /mnt/huge ] && [ ! -d /mnt/huge ]; then
#    echo "/mnt/huge exists but is not a directory. Removing..."
#    rm -f /mnt/huge
#fi
#mkdir -p /mnt/huge
#mount -t hugetlbfs none /mnt/huge

for ((i=0; i<${#pf_list_ixgbe[@]}; i++)); do
    pf="${pf_list_ixgbe[$i]}"
    
    # bring up the PF interface
    # this is required for the VF to work in the VMs
    ip link set "$pf" up

    device_dir="/sys/class/net/$pf/device"
    if [[ -d "$device_dir" ]]; then
        # For each PF we create one VF with the specified GUIDs
        # We bring it up so it is active
        echo 0 > "$device_dir/sriov_numvfs"  # Disable VFs first
        echo $num_vfs_per_pf > "$device_dir/sriov_numvfs"
    fi
    #for ((vf=0; vf<num_vfs_per_pf; vf++)); do
        #echo 1 > "$device_dir/virtfn$vf/enable"  # Enable the VF
        # Generate a unique MAC address for each VF
        # Format: 02:00:00:XX:YY:ZZ (locally administered, unicast)
    #    mac=$(printf "02:00:00:%02x:%02x:%02x" $i $vf 0)
    #    echo "Assigning MAC $mac to VF $vf on $pf"
    #    ip link set "$pf" vf $vf mac $mac
    #done
done

for ((i=0; i<${#pf_list_mlx5[@]}; i++)); do
  pf="${pf_list_mlx5[$i]}"
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
        

        vf_func=$((vf + 2))
        if [ $vf_func -le 7 ]; then
            # Still on device 00
            device=0
            func=$vf_func
        else
            # Wrap to next device
            device=1
            func=$((vf_func - 8))
        fi
        
        address=$(printf "0000:%02x:%02x.%x" $((i+1)) $device $func)

        echo "GUID Node: $guid_node"
        echo "GUID Port: $guid_port"
        echo "PCI Address: $address"

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

