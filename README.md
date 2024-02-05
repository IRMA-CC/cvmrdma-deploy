# CVMRDMA-deploy

This repository contains helper scripts to build CVMRDMA

1. packaged in a VM image
2. bare-metal


## WARNING: `rsync ..` !

This repository assumes that the parent directory (`cvmrdma-deploy/..`) should be deployed
to the remote machine: **EVERYTHING** in this directory will be copied to the remote machine!

The expected directory layout is as follows:

```shell
cvmrdma-project
├── cvmrdma-linux
├── cvmrdma-buildroot
├── cvmrdma-deploy
├── cvmrdma-rdma-core
├── ibverbs-test-app
```

This layout is *required* as relative paths in `cvmrdma-buildroot` point to the local sources for `cvmrdma-linux`, `cvmrdma-rdma-core` and `ibverbs-test-app`. The scripts `run{_sev}.sh` in `cvmrdma-deploy` also use relative paths
to `cvmrdma-buildroot`.


## WARNING: OpenSM ate my hard drive!

OpenSM is a configuration daemon required for RDMA operations. However, when running in our highly non-standard setting, OpenSM logs so much that it can reliably fill up the multi-TiB in drive in a matter of hours! To avoid surprises, I recommend to *prevent* OpenSM from autostarting at boot, and to run it manually **with a logging cap**:

```shell
sudo opensm --log_limit 32
```

## Remote machines selection

The machines to deploy to are defined in `deploy.py`. For instance:

```python
HOSTS = [
    ("sectrs235", "cascadelake"),
    ("sectrs245", "icelake-server"),
    ("glados", "znver3") # znver4 not supported by gcc 10
]
```

The tuples contain the SSH target name (in your `.ssh/config`) and the machines architecture (passed to `-march`).

Example matching `.ssh/config`:

```
Host glados
    HostName glados.XXXXXXX.ch
    User foo
    IdentityFile ~/.ssh/foo_glados_ed25519
```

## CVMRDMA bare metal

### Building

`cvmrdma/` contains a CMake "ExternalProject" that will

1. Download and build CVMRDMA's dependancies (Capn'Proto, libsodium)
2. Build CVMRDMA
3. Build ibverbs-test-app

This build configuration should be usable directly with CMake, but the expected way to use it is through `deploy.py`:

```shell
./deploy.py -b cvmrdma -t Release
# builds in: $HOME/cvmrdma-build/cvmrdma-Release
# installs in: $HOME/cvmrdma-install/cvmrdma-Release


# or

./deploy.py -b cvmrdma -t Debug
# builds in: $HOME/cvmrdma-build/cvmrdma-Debug
# installs in: $HOME/cvmrdma-install/cvmrdma-Debug
```

The Debug and Release configurations can live side by side.

### Running

You can then run CVMRDMA directly on the host:

```shell
# (assuming OpenSM is already running)

cd $HOME/cvmrdma-build/cvmrdma-Release
LD_LIBRARY_PATH="./install/lib" ./install/bin/ibtest --server

LD_LIBRARY_PATH="./install/lib" ./install/bin/ibtest --client 10.0.0.3
```


## CVMRDMA in (C)VMs

### Downloading the toolchain

The Buildroot project will assume that an existing toolchain has been setup at `${HOME}/cvmrdma-install/toolchain-x86-64-v3`.

`deploy.py` can automatically download and relocate the toolchain for us:

```shell
./deploy.py -t toolchain
```

TRIVIA: This downloads prebuilt Bootlin toolchains (from https://toolchains.bootlin.com/releases_x86-64-v3.html). We're using x86-64-v3 psABI (https://en.wikipedia.org/wiki/X86-64#Microarchitecture_levels) to get a libc optimized for our hardware (rather than for the generic x64-64 platform). Our `Zen 4` machine SHOULD also work with x86-64-v4, but VMs built with this toolchain failed to boot (invalid instruction exception). Why? 

### Building

deploy.py will copy all the local sources to the remote machine, configure the Buildroot project, and then start the build.

The configuration step includes creating a `local.mk` file pointing to the local sources, a step that you have to do manually if you're not using deploy.py.

```shell
# 1st build

./deploy.py -b br-sev -t Release
# configures and builds in $HOME/cvmrdma-install/br-sev-Release

# or enable debug symbols/assertions
./deploy.py -b br-sev -t Debug
# configures and builds in $HOME/cvmrdma-install/br-sev-Debug
```

You can change the configuration directly on the machine

```shell
ssh glados
cd $HOME/cvmrdma-install/br-sev-Release
make menuconfig
make linux-menuconfig

# rebuild
make
```

You can rebuild packages from `deploy.py` or directly on the remote machines using `make <pkg>-rebuild`:

```shell
./deploy.py -r linux ibverbs-test-app rdma-core-cvmrdma -t Release
```

### Running

You can run the image in a normal VM or in a CVM. The scripts are designed to run a pair of VMs, one with ID 3, the other with ID 4:

```shell
ssh glados
cd "$HOME/cvmrdma-src/cvmrdma-deploy"


# run br-sev-Debug in normal VMs
sudo ./run.sh 3 Debug
sudo ./run.sh 4 Debug

# run br-sev-Release in CVMs
sudo ./run_sev.sh 3 Release
sudo ./run_sev.sh 4 Release
```

The scripts starts each VM with:

- a passed through mlx5 IB adapter:
    + if the adapters change location in the machine, you have to change their PCI addresses in the script (`0000:49:00.0` and `0000:4f:00.0`)
- a MACVTAP Ethernet device 
    + if the Ethernet cable changes ports, you have to change the scripts too (for now: `enp161s0f1` and `eno2`)
    + using vhost-net, for better performance
- a p9 directory, pointing to `cvmrdma-install/br-sev` on the host (to access binaries after a rebuild, without rebooting the VM).

Once in the VMs, you have to setup IPs and Wireguard with the corresponding script. This also starts OpenSM on VM 3:

```shell
VM3> source setup_vm_3.sh 
VM4> source setup_vm_4.sh

# then you can ping

# over plain IP
VM3> mtr 192.10.0.4
# over Wireguard
VM3> mtr 10.0.0.4

# and run rdma programs
VM3> ibtest -s
VM4> ibtest -c 10.0.0.3
```

WARN: `run{_sev}.sh` unbinds the mlx5 devices from the mlx5_ib kernel driver! Even after the VMs are stopped, the devices are not re-attached to the driver. To use the devices again from the host, run:

```shell
for p in 0000:49:00.0 0000:49:00.1 0000:4f:00.0  0000:4f:00.1; do
    echo $p | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind | sudo tee /sys/bus/pci/drivers/mlx5_core/bind;
done
```