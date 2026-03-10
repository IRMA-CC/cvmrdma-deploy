#!/bin/bash

PRIVFILE="privkeys.txt"
PUBFILE="pubkeys.txt"

wait_for_iface() {
    local iface="$1"
    local timeout_sec="${2:-15}"
    local i

    for ((i=0; i<timeout_sec; i++)); do
        if ip link show "$iface" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "Error: Timed out waiting for interface $iface" >&2
    return 1
}

get_key() {
    # vm's start with 3, so we subtract 2 to get the correct line number
    local line_num=$(($1 - 2))
    local key_type=$2
    
    # Validate line number
    if ! [[ "$line_num" =~ ^[0-9]+$ ]] || [ "$line_num" -lt 1 ]; then
        echo "Error: Line number must be a positive integer." >&2
        return 1
    fi
    
    # Determine which file to use based on second parameter
    local keyfile
    if [ "$key_type" = "priv" ] || [ "$key_type" = "private" ]; then
        keyfile="$PRIVFILE"
    elif [ "$key_type" = "pub" ] || [ "$key_type" = "public" ]; then
        keyfile="$PUBFILE"
    else
        echo "Error: Key type must be 'priv' or 'pub'" >&2
        return 1
    fi

    # Extract key from file by line number
    local key=$(sed -n "${line_num}p" "$keyfile")

    if [ -z "$key" ]; then
        echo "Error: No key found at line $line_num in $keyfile" >&2
        return 1
    fi
    
    # Return the key via echo
    echo "$key"
    return 0
}

if [ $# -ne 1 ]; then
  echo "Usage: $0 <vm_id>"
  exit 1
fi

vm_id=$1

# Create list of all VM IDs (3 to 6) and remove current vm_id
all_vms=(3 4 5 6 7 8 9 10 11)
peer_vms=()
for vm in "${all_vms[@]}"; do
    if [ "$vm" != "$vm_id" ]; then
        peer_vms+=("$vm")
    fi
done



# ip link set up dev eth0
# ip addr add 10.0.2.15/24 dev eth0
# ip route add default via 10.0.2.2 
# echo "nameserver 10.0.2.3" > /etc/resolv.conf

echo "Setup enp6s0"

ip addr add 192.168.122.${vm_id}/24 dev enp6s0
ip link set up enp6s0
ip link set dev enp6s0 mtu 1500

echo "Setup enp5s0"

#modprobe ixgbe
# we need to use a specific driver for VFs
modprobe ixgbevf
ip addr add 192.10.0.${vm_id}/24 dev enp5s0
ip link set up enp5s0
ip link set dev enp5s0 mtu 9710

echo "Setup ibp4s0"

modprobe ib_ipoib
wait_for_iface ibp4s0 20 || { [[ "${BASH_SOURCE[0]}" != "$0" ]] && return 1 || exit 1; }
ip addr add 10.1.1.${vm_id}/24 dev ibp4s0
ip link set up ibp4s0
# echo connected > /sys/class/net/ibp4s0/mode
# echo 65400 > /sys/class/net/ibp4s0/mtu

echo "Setup wg0, wg1, wg2"

# Get the private key from file based on VM ID
MY_PRIVKEY=$(get_key "$vm_id" "priv")
echo $MY_PRIVKEY > $HOME/privkey.key

echo "PUBKEY:"
wg pubkey < $HOME/privkey.key

# Setup WireGuard interface wg0
ip link add dev wg0 type wireguard
ip link set dev wg0 mtu 9600
ip addr add 10.0.0.${vm_id}/24 dev wg0
ip link set up dev wg0
wg set wg0 private-key $HOME/privkey.key listen-port 51820

# Add peers to wg0
for peer_vm in "${peer_vms[@]}"; do
    peer_pubkey=$(get_key "$peer_vm" "pub")
    if [ $? -eq 0 ]; then
        wg set wg0 peer "$peer_pubkey" \
            allowed-ips 10.0.0.${peer_vm}/32 \
            endpoint 192.10.0.${peer_vm}:51820
    fi
done

# Setup WireGuard interface wg1
ip link add dev wg1 type wireguard
ip link set dev wg1 mtu 64000
ip addr add 10.0.3.${vm_id}/24 dev wg1
ip link set dev wg1 up
wg set wg1 private-key $HOME/privkey.key listen-port 51821

# Add peers to wg1
for peer_vm in "${peer_vms[@]}"; do
    peer_pubkey=$(get_key "$peer_vm" "pub")
    if [ $? -eq 0 ]; then
        wg set wg1 peer "$peer_pubkey" \
            allowed-ips 10.0.3.${peer_vm}/32 \
            endpoint 10.1.1.${peer_vm}:51821
    fi
done

ip link add dev wg2 type wireguard
ip link set dev wg2 mtu 1400
ip addr add 10.0.4.${vm_id}/24 dev wg2
ip link set dev wg2 up
wg set wg2 private-key $HOME/privkey.key listen-port 51822

# Add peers to wg2
for peer_vm in "${peer_vms[@]}"; do
    peer_pubkey=$(get_key "$peer_vm" "pub")
    if [ $? -eq 0 ]; then
        wg set wg2 peer "$peer_pubkey" \
            allowed-ips 10.0.4.${peer_vm}/32 \
            endpoint 192.168.122.${peer_vm}:51822
    fi
done

export CVMRDMA_BIND_ADDR="*:3456"
export CVMRDMA_AEAD="aegis128x4"
export CVMRDMA_SHARED_KEY="2dcfa4058886bc0d5f9bfaded6c4b9767da3841ca83ee46f16a616aa5cd9494d"

# backwards compatibility
if [[ $vm_id -eq 3 ]]; then
    export CVMRDMA_REMOTE_ADDR="10.0.0.4:3456"
fi 

if [[ $vm_id -eq 4 ]]; then
    export CVMRDMA_REMOTE_ADDR="10.0.0.3:3456"
fi 

/home/ubuntu/mnt/cvmrdma-manager/cvmrdma_manager &

#opensm &