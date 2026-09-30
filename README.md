# IRMA
This document is intended to explain how to deploy and run IRMA on AMD SEV and Intel TDX.
**Important**: IRMA was originally called "CVMRDMA" this still reflects in many of the namings of repositories and folders.

In the following we explain how to deploy CVMRDMA on two hosts for either AMD SEV SNP or Intel TDX.
We assume each host to be equipped with a Mellanox ConnectX-5 RDMA-NIC and a Intel X540 NIC. The Intel X540 NIC was purely used for TCP and TLS baseline mesaurements and is not required for CVMRDMA, but might be used in some scripts for connection establishment via TCP. If you do not have an Intel X540 NIC, you will need to remove the code in the qemu boot scripts attaching them to the CVMs and any scripts using their assigned ips.

## Installing the host kernel

### AMD SEV SNP
IRMA depends on the [[QEMU]] version of [AMDSEV](https://github.com/AMDESE/AMDSEV?tab=readme-ov-file#faq-2), however the qemu bundled with AMDSEV by default does not have user netdev enabled. 
To enable it open common.sh (after checking out snp-latest) and add `--enable-slirp --enable-user` to the qemu `./configure` line so it reads
```bash
run_cmd ./configure --enable-slirp --enable-user --target-list=x86_64-softmmu --prefix=$DEST
```
Afterwards follow the instructions of AMDSEV to install an SEV-SNP enabled kernel.
In our test setup the AMD kernel was 6.11.0-rc3-snp-host-85ef1ac03941
### Intel TDX
IRMA depends on an Intel TDX compatible kernel to be installed. Follow section 4 at https://github.com/canonical/tdx to install the host kernel. To be able to enable all Bios options required for Intel TDX, the board needs all DIMM slots to be equipped. (e.g. we noticed that `Software Guard Extension (SGX)` could not be enabled without all DIMM slots occupied. Even though we run Intel TDX CVMs, Intel TDX depends on Intel SGX this option needs to be enabled for Intel TDX machines to boot properly)
## Installing Mellanox ConnectX-5 driver on the host and configuring NICs
To be able to assign GUIDs (that opensm requires for routing) to the Mellanox ConnectX-5 RNIC we need to install the mellanox linux drivers from https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/

```bash
tar -xvf MLNX_OFED_LINUX-<version>.tgz
cd MLNX_OFED_LINUX-<version>/
sudo ./mlnxofedinstall --add-kernel-support --force
```

 Issues we encountered on one host machine during installation and possible fixes:
- Some packages are incompatible: By adding --force to the last package old packages are automatically replaced
- Linux headers of custom AMDSEV installation are not installed: The AMDSEV/linux folder should contain the header files of the custom kernel after installation and can be installed with ```sudo dpkg -i linux-headers-6.11.0-rc3-snp-host-85ef1ac03941_6.11.0-rc3-g85ef1ac03941-2_amd64.deb```
- We need to unload modules using the rdma nic:
	- sudo rmmod rpcrdma 
	- sudo rmmod rdma_cm
- We had the case that knem and xpmem were not building on some machines for custom kernels. If you don't need them simply remove them. They are located in the tgz file in the src folder of MLNX_OFED. Unpack the tgz, delete the source tgz files of kem and xpmem and then zip it again.
- Alternative:
	- Remove autoreconf
		- For xpmem and knem: Edit debian/rules and change any occurrences of ```dh $@ --with autoreconf``` to ```dh $@```
		- For xpmem: edit debian/rules in the xpmem tgz and add:
```bash
override_dh_autoreconf:
	@echo "Skipping dh_autoreconf (legacy autotools)"
```


After the MLNX_OFED was installed correctly, we can now configure the NICs. 
To start the driver run 
```bash
sudo mst start
```
Then configure the first port of the NIC to be in IB mode and the second port to ethernet mode:
```bash
# Set Port 1 to IB
sudo mstconfig -d mlx5_0 set LINK_TYPE_P1=1

# Set Port 2 to Ethernet
sudo mstconfig -d mlx5_0 set LINK_TYPE_P2=2
```
This is saved in the RNIC and does not reset after a reset of the machine.

Once this is configured run ```sudo vf.sh``` (AMD SEV-SNP) or ```sudo tdx_adv_vf.sh``` (Intel TDX) to configure the virtual functions using SRIOV and OpenSM on each host. This script must be run after each reboot to configure the NICs again, therefore it also starts mst.
Please note that tdx_adv_vf.sh is more general and will very likely work on AMD SEV-SNP (apart from thge OpenSM startup were you will need to adapt the server names), while the vf.sh requires fixed PCIe Addresses for the NICs. Furthermore, these scripts start OpemSM on one of the hosts by filtering the names. OpenSM manages the routing between the NICs.
To check that all connections between the Mellanox ConnectX-5 Nics have been established successfully run
```bash
ibv_devinfo
# Expected output: Each listed device (both phyiscal and virtual) should have "state" set to "PORT_ACTIVE (4)"
```

## WARNING: OpenSM ate my hard drive
OpenSM is a configuration daemon required for RDMA operations. However, when running in our highly non-standard setting, OpenSM logs so much that it can reliably fill up the multi-TiB in drive in a matter of hours! To avoid surprises, I recommend to _prevent_ OpenSM from autostarting at boot, and to run it manually **with a logging cap**:

```bash
sudo opensm --log_limit 32
```

## Running CVM
In this section we will explain how to run CVMs on AMD SEV-SNP and Intel TDX.

Warning: Most repositories have multiple branches, a good rule of thumb is to use the most recent one.

### AMD SEV SNP
First download all required repositories on one of your hosts. This host machine will act as your main development machine.
The folder structure should look like this:
```
leo-cvmrdma-src
├── cvmrdma-linux
├── cvmrdma-buildroot
├── cvmrdma-deploy
├── cvmrdma-rdma-core
├── cvmrdma-manager
```
Please note, that many run scripts refer to the leo-cvmrdma-src root folder and might break if it has a different name.
Here is a quick explanation of each repository:
- cvmrdma-buildroot: Uses buildroot to build and package the other repositories and creates a bootable image to run inside a CVM
- cvmrdma-deploy: Contains all scripts required to build and run IRMA
- cvmrdma-linux: The modified Linux kernel used by IRMA
- cvmrdma-rdma-core: The modified libibverbs library used by IRMA
- cvmrdma-manager: Manager used to manage incoming and outgoing connections for applications connecting using IRMA

#### Downloading the toolchain

The Buildroot project will assume that an existing toolchain has been setup at `${HOME}/leo-cvmrdma-install/toolchain-x86-64-v3`.
`deploy_local_sev.py` will download the toolchain for us and then sync it to the other host. This host needs to be specified in deploy_local_sev.py and the local host needs ssh access to the remote host.

```
./deploy_local_sev.py -b toolchain
```
TRIVIA: This downloads prebuilt Bootlin toolchains (from [https://toolchains.bootlin.com/releases_x86-64-v3.html](https://toolchains.bootlin.com/releases_x86-64-v3.html)). We're using x86-64-v3 psABI ([https://en.wikipedia.org/wiki/X86-64#Microarchitecture_levels](https://en.wikipedia.org/wiki/X86-64#Microarchitecture_levels)) to get a libc optimized for our hardware (rather than for the generic x64-64 platform). Our `Zen 4` machine SHOULD also work with x86-64-v4, but VMs built with this toolchain failed to boot (invalid instruction exception). Why?
#### Building

The project requires the libaegis library to be installed in /usr/local
Clone the project from https://github.com/aegis-aead/libaegis
And compile it using:
```bash
mkdir build
cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr/local ..
sudo make install
```
[[Ubuntu]] 22.04 only ships with an old libsodium version (10.0.18), we require 10.0.19:
```bash
sudo apt remove libsodium-dev libsodium23
# Download and build the latest libsodium
cd /tmp
wget https://download.libsodium.org/libsodium/releases/libsodium-1.0.19.tar.gz
tar -xzf libsodium-1.0.19.tar.gz
cd libsodium-stable

# Configure, build and install
./configure
make
sudo make install

# Update library cache
sudo ldconfig
```

deploy_local_sev.py will build IRMA on the local host by configure the Buildroot project and then copy the source and build files to the remote all the remote host., 

Good to know: There is a legacy script deploy.py which uses a different approach for editing and deploying. It allows you to edit the source files on a different machine and then sync them to the remotes. Each remote then locally builds IRMA using buildroot. However, this file is not maintained and might be broken.

```bash
# 1st build

./deploy_local_sev.py -b br-sev -t Release
# configures and builds in $HOME/cvmrdma-install/br-sev-Release

# or enable debug symbols/assertions
./deploy_local_sev.py -b br-sev -t Debug
# configures and builds in $HOME/cvmrdma-install/br-sev-Debug
```

Good to know: Some applications might require a little love to get build properly. A good alternative is to build them independently of buildroot and simply access them through the p9 mount directory to run them.

You can change the configuration directly on main host machine

```bash
cd $HOME/leo-cvmrdma-install/br-sev-Release
make menuconfig
make linux-menuconfig
# rebuild
make
```

You can rebuild packages from `deploy_local_sev.py` or directly on the host using `make <pkg>-rebuild`:

```bash
./deploy_local_sev.py -r linux rdma-core-cvmrdma -t Release
```

#### Running

You can run the image in a normal VM or in a CVM. The scripts are designed to run a pair of VMs

```bash
ssh host1
cd "$HOME/cvmrdma-src/cvmrdma-deploy"
sudo ./2run_sev.sh 0 # as a cvm
sudo ./2run.sh 0 # as a vm

# in a seperate window
ssh host2
cd "$HOME/cvmrdma-src/cvmrdma-deploy"
sudo ./2run_sev.sh 0 # as a cvm
sudo ./2run.sh 0 # as a vm
```
The scripts starts each CVM/VM with:
- a passed through mlx5 IB adapter:
    - if the adapters change location in the machine, you have to change their PCI addresses in the script (`0000:01:00.0` and `0000:02:00.0`)
- a p9 directory, pointing to `leo-cvmrdma-install/br-sev` (or `leo-cvmrdma-src`  depending on the script) on the host (to access binaries and evaluation).
- The script still uses a deprecated argument to assign the VMID and assumes 0 to be passed. Instead the VMID is modified for other hosts by checking the hostname in the script. You will need to adapt the hostnames based on your machine

Even when using a VM, IRMA is not disabled by default. To use raw normal rdma set ```export CVMRDMA_DISABLE=1``` inside the VM. This can be set/unset freely between application execution while the VM is running and does not require a restart. Please note, that even when CVMRDMA_DISABLE=1 is set, it does still use the modified linux kernel. CVMRDMA_DISABLE=1 will not work in CVMs, because libibverbs is by default incompatible with SWIOTLB bounce buffering (see paper for details).

Once in the VMs, you have to setup IPs and Wireguard with the corresponding script. This also starts OpenSM on VM 3:

```bash
# because of backwards compatabiltiy with the old code base ids inside vms start with 3.
VM1> source setup_vm.sh 3
VM2> source setup_vm.sh 4

# then you can ping

# over plain IP
VM1> mtr 192.10.0.4
# over Wireguard
VM1> mtr 10.0.0.4

# and run rdma programs
```

### Intel TDX
First download all required repositories on one of your hosts. This host machine will act as your main development machine.
The folder structure should look like this:
```
leo-cvmrdma-src
├── cvmrdma-linux-tdx
├── cvmrdma-deploy
├── cvmrdma-rdma-core
├── cvmrdma-manager
```
For details about all packages see AMD SEV-SNP.
- cvmrdma-linux-tdx: The modified linux kernel used in the tdx image
#### Downloading the TDX image
Instead of using buildroot to create an image, we build an image with out custom kernel based on a ubuntu cloud image.
We use the modified linux kernel and use cvmrdma-linux-tdx as kernel in our ubuntu cloud image.

Because we use a prebuild-image, there is no automatic build pipeline. 
Instead, once booted inside the CVM we can build the IRMA components using tdx_build.sh, which are mounted in through the p9 mount point.
Please note, that it might also work to build these components on the host machine, but we haven't tested it.
The case studies need to be compiled individually based on their README.md

#### Running

You can run the image in a normal VM or in a CVM. The scripts are designed to run a pair of VMs

```bash
ssh host1
cd "$HOME/cvmrdma-src/cvmrdma-deploy"
sudo ./tdx_2run_cvm.sh 0 # as a cvm
sudo ./tdx_2run_vm.sh 0 # as a vm

# in a seperate window
ssh host2
cd "$HOME/cvmrdma-src/cvmrdma-deploy"
sudo ./tdx_2run_cvm.sh 0 # as a cvm
sudo ./tdx_2run_vm.sh 0 # as a vm
```
The scripts starts each CVM/VM with:
- a passed through mlx5 IB adapter:
    - if the adapters change location in the machine, you have to change their PCI addresses in the script (`0000:01:00.0` and `0000:02:00.0`)
- a p9 directory, pointing to `leo-cvmrdma-install/br-sev` (or `leo-cvmrdma-src`  depending on the script) on the host (to access binaries and evaluation).
- The script still uses a deprecated argument to assign the VMID and assumes 0 to be passed. Instead the VMID is modified for other hosts by checking the hostname in the script. You will need to adapt the hostnames based on your machine

Even when using a VM, IRMA is not disabled by default. To use raw normal rdma set ```export CVMRDMA_DISABLE=1``` inside the VM. This can be set/unset freely between application execution while the VM is running and does not require a restart. Please note, that even when CVMRDMA_DISABLE=1 is set, it does still use the modified linux kernel. CVMRDMA_DISABLE=1 will not work in CVMs, because libibverbs is by default incompatible with SWIOTLB bounce buffering (see paper for details).

Once in the VMs, you have to setup IPs and Wireguard with the corresponding script. This also starts OpenSM on VM 3:

```bash
# because of backwards compatabiltiy with the old code base ids inside vms start with 3.
VM1> source setup_vm.sh 3
VM2> source setup_vm.sh 4

# then you can ping

# over plain IP
VM1> mtr 192.10.0.4
# over Wireguard
VM1> mtr 10.0.0.4

# and run rdma programs
```