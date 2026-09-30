#!/usr/bin/env python3

import argparse
import asyncio
from pathlib import Path
import itertools
import sys
import subprocess
import asyncio.subprocess

#("xray", "/home/ubuntu/Documents/leo-cvmrdma-src", "/home/ubuntu/Documents/leo-cvmrdma-install/br-sev-Release/images"),
HOSTS = [
    # ("leafblower", "/home/fheinen/data/leo-cvmrdma-src", "/home/fheinen/data/leo-cvmrdma-install/br-sev-Release/images"),
    # ("turbo", "/home/fheinen/leo-cvmrdma-src", "/home/fheinen/leo-cvmrdma-install/br-sev-Release/images"),    
]

# SSH control dir
ctl = Path(".ssh_control/")

# Architecture of current machine (oven)
CURRENT_ARCH = "znver3"

def flatten(list_of_lists):
    "Flatten one level of nesting"
    return list(itertools.chain.from_iterable(list_of_lists))

def parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("-b", "--build", dest="builds", action="append", nargs="+", default=[])
    parser.add_argument("-r", "--rebuild-cvm", dest="rebuild_cvm", action="append", nargs="+", default=[])
    parser.add_argument("-t", "--build-type", dest="build_type", default="Release")
    return parser.parse_args(argv[1:])


def build_locally(builds, rebuild_cvm, build_type):
    """Build directly on the oven machine (current machine)"""
    srcdir = Path.cwd().parent
    build_path = srcdir / "cvmrdma-deploy"
    
    build_init = f"""\
export CC=gcc-10;
export CXX=g++-10;
export CFLAGS=\"-march={CURRENT_ARCH} -fno-omit-frame-pointer \";
export CXXFLAGS=\"-march={CURRENT_ARCH} -fno-omit-frame-pointer \";
export LDFLAGS=\" \";
cd {build_path} || exit;
"""

    build_cmd = ""
    if len(builds) > 0:
        build_cmd = f"make {' '.join(builds)} BUILD_TYPE={build_type};"

    rebuild_cvm_cmd = ""
    if len(rebuild_cvm) > 0:
        rebuild_cvm_cmd = f"./scripts/rebuild_br_targets.sh {build_type} {' '.join(rebuild_cvm)};"

    if len(builds) > 0 or len(rebuild_cvm) > 0:
        build_sequence = "\n".join([build_init, build_cmd, rebuild_cvm_cmd])
        print("[oven] Running build locally:")
        print(build_sequence)
        result = subprocess.run(build_sequence, shell=True, executable="/bin/bash")
        if result.returncode != 0:
            print("[oven] Build failed!")
            sys.exit(1)
        print("[oven] Build completed")
    else:
        print("[oven] No build targets specified")

files = ["disk.qcow2", "OVMF_CODE.fd"]
async def sync_to_host(host_spec):
    """Sync source code and built artifacts directly to remote host"""
    host, dst_dir, dst_images = host_spec
    ssh_ctl = ctl / "%L-%r@%h:%p"
    # srcdir = Path("leo-cvmrdma-src")
    # dst_dir = "/home/fheinen/data/leo-cvmrdma-src"
    
    src_images = "/home/fheinen/leo-cvmrdma-install/br-sev-Release/images"
    # dst_images = "/home/fheinen/data/leo-cvmrdma-install/br-sev-Release/images"

    # Start SSH session to destination
    print(f"[{host}] Start ssh session")
    p = await asyncio.create_subprocess_exec("ssh", "-Nf", "-o", "ControlMaster=auto", "-S", str(ssh_ctl), "-o", "ControlPersist=60", host)
    await p.communicate()

    print(f"[{host}] Ensure destination directories exist")
    mkdir_cmd = f"mkdir -p {dst_dir} {dst_images}"
    p = await asyncio.create_subprocess_exec("ssh", "-S", str(ssh_ctl), host, mkdir_cmd)
    await p.communicate()

    p = await asyncio.create_subprocess_exec("rsync", "-e", f'ssh -S {str(ssh_ctl)}', "-aPzhv", "--delete", "--exclude=.*", "--exclude=cvmrdma-buildroot/dl/*", "..", f"{host}:{dst_dir}")
    await p.communicate()

    for f in files:
        p = await asyncio.create_subprocess_exec("rsync", "-e", f'ssh -S {str(ssh_ctl)}', "-aPzhv", f"{src_images}/{f}", f"{host}:{dst_images}/{f}")
        await p.communicate()
    
    # Sync built images directly from oven to destination
    # print(f"[{host}] Sync built artifacts")
    # p = await asyncio.create_subprocess_exec("rsync", "-e", f'ssh -S {str(ssh_ctl)}', "-aPzhv", "--delete", f"{src_images}/", f"{host}:{dst_images}/")
    # await p.communicate()

    print(f"[{host}] Sync completed")


async def main(argv):
    # Setup SSH control directory
    ctl.mkdir(exist_ok=True)

    args = parse_args(argv)
    
    # Build locally on oven machine
    print("[oven] Starting local build on oven machine")
    build_locally(flatten(args.builds), flatten(args.rebuild_cvm), args.build_type)

    # Sync to all remote hosts
    t = []
    for h in HOSTS:
        task = asyncio.create_task(sync_to_host(h))
        t.append(task)

    await asyncio.gather(*t)

    print("Done")
    

if __name__ == "__main__":
    asyncio.run(main(sys.argv))
