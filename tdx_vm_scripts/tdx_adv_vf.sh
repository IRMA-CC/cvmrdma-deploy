#!/bin/bash

MACHINE_ID=0

start_opensm() {
    # load drivers required for Mellanox devices and start OpenSM on the main server
    modprobe vfio-pci
    mst start
    modprobe mst-pci
    mst status

    HOSTNAME=$(hostname)

    case "$HOSTNAME" in
    TurboDieselXylophone)
        MAIN_SERVER=1
        MACHINE_ID=0
        ;;
    sectrs-tripledamagexray)
        MAIN_SERVER=0
        MACHINE_ID=1
        ;;
    *)
        echo "Unknown server: $HOSTNAME" >&2
        exit 1
        ;;
    esac

    echo "Server name: $HOSTNAME"
    echo "Main server: $MAIN_SERVER"


    # only start OpenSM on the main server to avoid conflicts
    if [[ $MAIN_SERVER -eq 1 ]]; then
        echo "Starting OpenSM..."

        if ! pgrep -x opensm > /dev/null; then
            echo "opensm not running, starting it..."
            opensm --log_limit 32 &
        else
            echo "opensm is already running."
        fi
    fi 
}

# get all interfaces associated with X540 devices, we will use these to configure SR-IOV on the Intel NICs
get_x540_ifaces() {
    local -n result=$1
    result=()

    local pci iface

    for pci in $(lspci -D | grep "X540" | awk '{print $1}'); do
        if [ -d "/sys/bus/pci/devices/$pci/net" ]; then
            for iface in /sys/bus/pci/devices/$pci/net/*; do
                result+=("$(basename "$iface")")
            done
        fi
    done
}

# This function sets up SR-IOV on the Intel X540 NICs, it creates the specified number of VFs on each PF and brings up the PF interfaces (thereby also bringing up the VFs).
setup_x540_sriov() {
    local num_vfs_per_pf="$1"
    shift
    local pf_list=("$@")

    local pf device_dir

    for pf in "${pf_list[@]}"; do
        echo "Configuring SR-IOV on PF: $pf"

        # Bring up the PF interface (required for VM VF usage)
        ip link set "$pf" up

        device_dir="/sys/class/net/$pf/device"

        if [[ -d "$device_dir" ]]; then
            echo "Resetting VFs on $pf"
            echo 0 > "$device_dir/sriov_numvfs"

            echo "Creating $num_vfs_per_pf VFs on $pf"
            echo "$num_vfs_per_pf" > "$device_dir/sriov_numvfs"
        else
            echo "WARNING: device directory not found for $pf"
        fi
    done
}

# This function checks for existing Intel X540 SR-IOV VFs and aborts if any are found to avoid conflicts with our configuration
check_existing_x540_sriov() {
    for pci in $(lspci -D | grep -i "X540" | awk '{print $1}'); do
        vfs=$(ls /sys/bus/pci/devices/$pci/virtfn* 2>/dev/null)

        if [[ -n "$vfs" ]]; then
            echo "WARNING: Intel X540 SR-IOV VFs already exist on PCI device $pci:"
            for vf in $vfs; do
                echo "  -> $(basename "$(readlink -f "$vf")")"
            done
            echo "Abort."
            exit 1
        fi
    done
}

# This function detects Mellanox devices, determines their SR-IOV base addresses, and checks if they are in IB or Ethernet mode. It populates the provided arrays with this information for later use in configuration.
get_mlx5_devices_and_sriov_bases() {
    local -n dev_list=$1
    local -n base_list=$2
    local -n mode_list=$3   # New array to track mode: 1=IB, 0=Ethernet

    dev_list=()
    base_list=()
    mode_list=()

    local ibdev name pci bus devfunc func base mode

    for ibdev in /sys/class/infiniband/*; do
        name=$(basename "$ibdev")
        pci=$(basename "$(readlink -f "$ibdev/device")")

        if lspci -s "$pci" | grep -qi "Mellanox"; then
            bus=$(echo "$pci" | awk -F':' '{print $2}')
            devfunc=$(echo "$pci" | awk -F':' '{print $3}')
            func=${devfunc##*.}

            # SR-IOV base addresses
            if [[ "$func" == "0" ]]; then
                base="${bus}:00"
            else
                base="${bus}:02"
            fi

            # Determine mode: IB=1, Ethernet=0
            if lspci -s "$pci" | grep -q "Infiniband controller"; then
                mode=1
            else
                mode=0
            fi

            dev_list+=("$name")
            base_list+=("$base")
            mode_list+=("$mode")
        fi
    done
}

# This function sets up SR-IOV on Mellanox devices, it creates the specified number of VFs on each PF, configures the GUIDs for IB mode, and brings up the VFs. It also checks for GUID mismatches after setting them.
setup_mlx5_sriov() {
    local num_vfs_per_pf="$1"
    local SERVER_ID="$2"
    local -n pf_list_mlx5="$3"
    local -n pci_list_mlx5="$4"
    local -n mode_list_mlx5="$5"

    local pf device_dir address_prefix
    local i vf guid_node guid_port address node_val port_val
    local vf_func device func

    for ((i=0; i<${#pf_list_mlx5[@]}; i++)); do
        pf="${pf_list_mlx5[$i]}"
        device_dir="/sys/class/infiniband/$pf/device"

        if [[ -d "$device_dir" ]]; then
            echo "Configuring PF $pf"

            echo 0 > "$device_dir/sriov_numvfs"
            echo "$num_vfs_per_pf" > "$device_dir/sriov_numvfs"

            # check if this PF is in IB mode, if so we need to set the GUIDs for the VFs, otherwise we can skip that step
            if [[ ${mode_list_mlx5[$i]} -eq 1 ]]; then
                
                for ((vf=0; vf<num_vfs_per_pf; vf++)); do
                    echo "Configuring VF $vf for PF $pf"

                    guid_node=$(printf "00:00:00:%02x:%02x:%02x:01:00" \
                        "$SERVER_ID" "$((i+1))" "$((vf+2))")

                    guid_port=$(printf "00:00:00:%02x:%02x:%02x:02:00" \
                        "$SERVER_ID" "$((i+1))" "$((vf+2))")

                    vf_func=$((vf + 2))

                    if [[ $vf_func -le 7 ]]; then
                        device=0
                        func=$vf_func
                    else
                        device=1
                        func=$((vf_func - 8))
                    fi

                    address_prefix="${pci_list_mlx5[$i]}"
                    address="0000:$address_prefix.$func"

                    echo "GUID Node: $guid_node"
                    echo "GUID Port: $guid_port"
                    echo "PCI Address: $address"

                    # Unbind VF from driver
                    echo "$address" > /sys/bus/pci/drivers/mlx5_core/unbind

                    echo "$guid_node" > "$device_dir/sriov/$vf/node"
                    echo "$guid_port" > "$device_dir/sriov/$vf/port"
                    echo "Up" > "$device_dir/sriov/$vf/policy"

                    node_val=$(cat "$device_dir/sriov/$vf/node")
                    port_val=$(cat "$device_dir/sriov/$vf/port")

                    if [[ "$node_val" != "$guid_node" ]]; then
                        echo "WARNING: node GUID mismatch for $pf VF $vf (set: $guid_node, read: $node_val)"
                    fi

                    if [[ "$port_val" != "$guid_port" ]]; then
                        echo "WARNING: port GUID mismatch for $pf VF $vf (set: $guid_port, read: $port_val)"
                    fi

                    # Rebind VF
                    echo "$address" > /sys/bus/pci/drivers/mlx5_core/bind
                done
            fi
        fi
    done
}

# This function checks for existing Mellanox SR-IOV VFs and aborts if any are found to avoid conflicts with our configuration
check_existing_mlx_sriov() {
    for pci in $(lspci -D | grep -i "Mellanox" | awk '{print $1}'); do
        vfs=$(ls /sys/bus/pci/devices/$pci/virtfn* 2>/dev/null)
        if [[ -n "$vfs" ]]; then
            echo "WARNING: Mellanox SR-IOV VFs already exist on $pci:"
            for vf in $vfs; do
                echo "  -> $(basename $(readlink -f $vf))"
            done
            echo "Abort."
            exit 1
        fi
    done
}

# first check if there are existing VFs on the X540 or Mellanox devices, if so abort to avoid conflicts
check_existing_x540_sriov
check_existing_mlx_sriov

start_opensm

num_vfs_per_pf=4

x540_ifaces=()
get_x540_ifaces x540_ifaces

echo "X540 interfaces:"
printf "%s\n" "${x540_ifaces[@]}"

mlx_devices=()
mlx_bases=()
mlx_modes=()  # New array to track mode: 1=IB, 0=Ethernet
get_mlx5_devices_and_sriov_bases mlx_devices mlx_bases mlx_modes

for i in "${!mlx_devices[@]}"; do
    echo "${mlx_devices[$i]} -> ${mlx_bases[$i]} (Mode: ${mlx_modes[$i]})"
done

setup_x540_sriov "$num_vfs_per_pf" "${x540_ifaces[@]}"
setup_mlx5_sriov "$num_vfs_per_pf" "$MACHINE_ID" mlx_devices mlx_bases mlx_modes

echo "SR-IOV configuration complete."