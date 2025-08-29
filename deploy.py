#!/usr/bin/env python3

import argparse
import asyncio
from pathlib import Path
import itertools
import sys

HOSTS_BUILD = [ ("oven", "znver3") ]

HOSTS = [
    ("leafblower", "znver3")
]


# SSH control dir
ctl = Path(".ssh_control/")


def flatten(list_of_lists):
    "Flatten one level of nesting"
    return list(itertools.chain.from_iterable(list_of_lists))

def parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("-b", "--build", dest="builds", action="append", nargs="+", default=[])
    parser.add_argument("-r", "--rebuild-cvm", dest="rebuild_cvm", action="append", nargs="+", default=[])
    parser.add_argument("-t", "--build-type", dest="build_type", default="Release")
    return parser.parse_args(argv[1:])


files = ["disk.qcow2", "OVMF_CODE.fd"]
async def copy_to_tmp():
    ssh_ctl_src = ctl / f"src-%L-%r@%h:%p"
    
    src = "/home/fheinen/leo-cvmrdma-install/br-sev-Release/images"
    local_tmp = Path("/tmp/leo-cvmrdma-images")

    # Start SSH sessions to both source (B) and destination (C)
    print(f"[{HOSTS_BUILD[0][0]}] Start ssh sessions")
    p = await asyncio.create_subprocess_exec("ssh", "-Nf", "-o", "ControlMaster=auto", "-S", str(ssh_ctl_src), "-o", "ControlPersist=60", HOSTS_BUILD[0][0])
    await p.communicate()

    for f in files:
        (local_tmp / f).unlink(missing_ok=True)
        local_tmp.mkdir(exist_ok=True)
        # Copy individual files from source (B) to local machine (A)
        print(f"Copy {f} from {HOSTS_BUILD[0][0]} to local")
        p = await asyncio.create_subprocess_exec("rsync", "-e", f'ssh -S {str(ssh_ctl_src)}', "-aPzhv", f"{HOSTS_BUILD[0][0]}:{src}/{f}", str(local_tmp / f))
        await p.communicate()

async def copy_one(host_spec):
    host, arch = host_spec
    ssh_ctl_dst = ctl / f"dst-%L-%r@%h:%p"
    srcdir = Path("leo-cvmrdma-src")
    
    dst = "/home/fheinen/leo-cvmrdma-install/br-sev-Release/images"
    local_tmp = Path("/tmp/leo-cvmrdma-images")

    # Start SSH sessions to both source (B) and destination (C)
    print(f"[{host}] Start ssh sessions")
    
    p = await asyncio.create_subprocess_exec("ssh", "-Nf", "-o", "ControlMaster=auto", "-S", str(ssh_ctl_dst), "-o", "ControlPersist=60", host)
    await p.communicate()

    print(f"[{host}] Sync parent directory")
    p = await asyncio.create_subprocess_exec("rsync", "-e", f'ssh -S {str(ssh_ctl_dst)}', "-aPzhv", "--delete", "--exclude=.*", "--exclude=cvmrdma-buildroot/dl/*", "..", f"{host}:{srcdir}")
    await p.communicate()
    
    for f in files:
        # Copy individual files from local machine (A) to destination (C)
        print(f"[{host}] Copy {f} to {host}")
        p = await asyncio.create_subprocess_exec("rsync", "-e", f'ssh -S {str(ssh_ctl_dst)}', "-aPzhv", str(local_tmp / f), f"{host}:{dst}/{f}")
        await p.communicate()


async def deploy_one(host_spec, builds, rebuild_cvm, build_type):
    host, arch = host_spec
    ssh_ctl = ctl / "%L-%r@%h:%p"
    srcdir = Path("leo-cvmrdma-src")

    print(f"[{host}] Start ssh session")
    p = await asyncio.create_subprocess_exec("ssh", "-Nf", "-o", "ControlMaster=auto", "-S", str(ssh_ctl), "-o", "ControlPersist=60", host)
    await p.communicate()

    print(f"[{host}] Sync parent directory")
    p = await asyncio.create_subprocess_exec("rsync", "-e", f'ssh -S {str(ssh_ctl)}', "-aPzhv", "--delete", "--exclude=.*", "--exclude=cvmrdma-buildroot/dl/*", "..", f"{host}:{srcdir}")
    await p.communicate()

#  -fsanitize=address -fsanitize=undefined -fno-sanitize-recover 
#  -fsanitize=thread

# export CFLAGS=\"-march={arch} -fno-omit-frame-pointer -fsanitize=thread \";
# export CXXFLAGS=\"-march={arch} -fno-omit-frame-pointer -fsanitize=thread \";
# export LDFLAGS=\"-fsanitize=thread \";

    print(f"[{host}] Build")
    build_init = f"""\
export CC=gcc-10;
export CXX=g++-10;
export CFLAGS=\"-march={arch} -fno-omit-frame-pointer \";
export CXXFLAGS=\"-march={arch} -fno-omit-frame-pointer \";
export LDFLAGS=\" \";
cd {srcdir}/cvmrdma-deploy/ || exit;
"""

    do_build=False

    build_cmd = ""
    if len(builds) > 0:
        do_build=True
        build_cmd=f"make {' '.join(builds)} BUILD_TYPE={build_type};"

    rebuild_cvm_cmd = ""
    if len(rebuild_cvm) > 0:
        do_build=True
        rebuild_cvm_cmd = f"./scripts/rebuild_br_targets.sh {build_type} {' '.join(rebuild_cvm)};"


    if do_build:
        build_sequence = "\n".join([ build_init, build_cmd, rebuild_cvm_cmd ])
        print("build_seq=\n", build_sequence)

        p = await asyncio.create_subprocess_exec("ssh", "-S", str(ssh_ctl), host, build_sequence)
        await p.communicate()

    print(f"[{host}] Deploy done")

async def main(argv):
    # start ssh session
    ctl.mkdir(exist_ok=True)

    args = parse_args(argv)
    
    t = []
    for h in HOSTS_BUILD:
        task = asyncio.create_task(deploy_one(h, flatten(args.builds), flatten(args.rebuild_cvm), args.build_type))
        t.append(task)

    await asyncio.gather(*t)

    await copy_to_tmp()

    for h in HOSTS:
        task = asyncio.create_task(copy_one(h))
        t.append(task)

    await asyncio.gather(*t)

    print("Done")
    

if __name__ == "__main__":
    asyncio.run(main(sys.argv))
