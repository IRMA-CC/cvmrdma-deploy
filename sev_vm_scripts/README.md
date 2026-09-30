# Overview of vm sev scripts

## vf.sh
Script to setup virtual functions and opensm on host devices.
Relies on fixed pci addresses, its probably best to use tdx_adv_vf.sh to get address independent setup (however you will need to adapt the host names in the script)

## run.sh and run_sev.sh
These scripts were used when only one machine was used for benchmarking instead of two.
It contains the oldest run logic and will probably fail with future versions of IRMA

## 2run.sh and 2run_sev.sh
Script to run a CVM in normal and sev mode. Designed to work for different machines.
Assumes the SEV host machines leafblower and oven. Fixed addresses for virtual functions that are incremented based on the vmid

