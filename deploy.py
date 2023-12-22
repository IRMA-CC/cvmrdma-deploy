#!/usr/bin/env python3

import argparse
import asyncio
from pathlib import Path
import itertools
import sys

HOSTS = [
#    ("sectrs235", "cascadelake"),
#    ("sectrs245", "icelake-server"),
    ("glados", "znver3") # znver4 not supported by gcc 10
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
    return parser.parse_args(argv[1:])


async def deploy_one(host_spec, builds, rebuild_cvm):
    host, arch = host_spec
    ssh_ctl = ctl / "%L-%r@%h:%p"
    srcdir = Path("cvmrdma-src")

    print(f"[{host}] Start ssh session")
    p = await asyncio.create_subprocess_exec("ssh", "-Nf", "-o", "ControlMaster=auto", "-S", str(ssh_ctl), "-o", "ControlPersist=60", host)
    await p.communicate()

    print(f"[{host}] Sync parent directory")
    p = await asyncio.create_subprocess_exec("rsync", "-e", f'ssh -S {str(ssh_ctl)}', "-aPzh", "--delete", "--exclude=.*", "..", f"{host}:{srcdir}")
    await p.communicate()


    print(f"[{host}] Build")
    build_init = f"""\
export CC=gcc-10;
export CXX=g++-10;
export CFLAGS=\"-march={arch} -fno-omit-frame-pointer -fsanitize=address -fsanitize=undefined -fno-sanitize-recover\";
export CXXFLAGS=\"-march={arch} -fno-omit-frame-pointer -fsanitize=address -fsanitize=undefined -fno-sanitize-recover\";
cd {srcdir}/cvmrdma-deploy/ || exit;
"""

    do_build=False

    build_cmd = ""
    if len(builds) > 0:
        do_build=True
        build_cmd=f"make {' '.join(builds)};"

    rebuild_cvm_cmd = ""
    if len(rebuild_cvm) > 0:
        do_build=True
        rebuild_cvm_cmd = f"./scripts/rebuild_br_targets.sh {' '.join(rebuild_cvm)};"


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
    for h in HOSTS:
        task = asyncio.create_task(deploy_one(h, flatten(args.builds), flatten(args.rebuild_cvm)))
        t.append(task)

    await asyncio.gather(*t)

    print("Done")
    

if __name__ == "__main__":
    asyncio.run(main(sys.argv))
