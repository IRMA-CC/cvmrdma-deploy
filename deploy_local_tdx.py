#!/usr/bin/env python3

import argparse
import asyncio
from pathlib import Path
import itertools
import sys
import subprocess
import asyncio.subprocess


HOSTS = [
    ("xray", "/home/ubuntu/Documents/leo-cvmrdma-src", "/home/ubuntu/Documents/tdx_data"),  
]

# Exclude patterns for rsync
EXCLUDE_PATTERNS = [
    ".*",
    "cvmrdma-buildroot/",
    "VMID_tmp_*",
    "perftest_*",
    "cvmrdma-linux/",
    "attested-tls/",
    "enc_results/",
    "farm/",
    "Hermes/",
    "linux-tdx-logging/",
    "loc/",
    "qperf/",
    "ratls/",
    "rdma-bench/",
    "spdk/",
    "YCSB/",
    "hdrdmacp_logs_*",
    "scalability_logs_*",
    "gam_logs_*",
    "irma_bench_*",
    "irma",
    "irma_*"
]

# SSH control dir
ctl = Path(".ssh_control/")

async def sync_to_host(host_spec):
    """Sync source code"""
    host, dst_dir, dst_images = host_spec
    ssh_ctl = ctl / "%L-%r@%h:%p"
    # srcdir = Path("leo-cvmrdma-src")
    # dst_dir = "/home/fheinen/data/leo-cvmrdma-src"
    
    src_images = "/home/fheinen/tdx_data"
    src_code = "/home/fheinen/leo-cvmrdma-src"

    # Start SSH session to destination
    print(f"[{host}] Start ssh session")
    p = await asyncio.create_subprocess_exec("ssh", "-Nf", "-o", "ControlMaster=auto", "-S", str(ssh_ctl), "-o", "ControlPersist=60", host)
    await p.communicate()

    print(f"[{host}] Ensure destination directories exist")
    mkdir_cmd = f"mkdir -p {dst_dir} {dst_images}"
    p = await asyncio.create_subprocess_exec("ssh", "-S", str(ssh_ctl), host, mkdir_cmd)
    await p.communicate()

    rsync_args = ["rsync", "-e", f'ssh -S {str(ssh_ctl)}', "-aHPzh", "--delete", "--checksum"]
    for pattern in EXCLUDE_PATTERNS:
        rsync_args.append(f"--exclude={pattern}")
    rsync_args.extend([f"{src_code}/", f"{host}:{dst_dir}/"])
    p = await asyncio.create_subprocess_exec(*rsync_args)
    await p.communicate()

    p = await asyncio.create_subprocess_exec("rsync", "-e", f'ssh -S {str(ssh_ctl)}', "-aHPzh", "--delete", f"{src_images}/", f"{host}:{dst_images}")
    await p.communicate()
    
    # Sync built images directly from oven to destination
    print(f"[{host}] Sync built artifacts")
    p = await asyncio.create_subprocess_exec("rsync", "-e", f'ssh -S {str(ssh_ctl)}', "-aPzhv", "--delete", f"{src_images}/", f"{host}:{dst_images}/")
    await p.communicate()

    print(f"[{host}] Sync completed")


async def main(argv):
    # Setup SSH control directory
    ctl.mkdir(exist_ok=True)

    # Sync to all remote hosts
    t = []
    for h in HOSTS:
        task = asyncio.create_task(sync_to_host(h))
        t.append(task)

    await asyncio.gather(*t)

    print("Done")
    

if __name__ == "__main__":
    asyncio.run(main(sys.argv))
