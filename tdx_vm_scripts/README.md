# Overview of tdx vm scripts

## vf.sh scripts
One of these scripts has to be used before running a vm/cvm on the host machine.
Use tdx_adv_vf.sh for easy setup of virtual functions and opensm, as it is independent of pcie addresses.
The other vf scripts are likely outdated.

## tdx_2run_vm.sh tdx_2run_cvm.sh
Scripts to run normal VM and CVM for Intel TDX. PCIe addresses are fixed, but automatically selected depending on the host machine turbo or xray.

## other scripts
Other scripts are outdated or do not work properly, but are kept for completness