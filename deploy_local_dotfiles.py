#!/usr/bin/env python3

import asyncio
from pathlib import Path
import asyncio.subprocess

#("xray", "/home/ubuntu/Documents/leo-cvmrdma-src", "/home/ubuntu/Documents/leo-cvmrdma-install/br-sev-Release/images"),
HOSTS = [
    # ("leafblower", "/home/fheinen/data/leo-cvmrdma-src", "/home/fheinen/data/leo-cvmrdma-install/br-sev-Release/images"),
    ("turbo", "/home/fheinen/leo-cvmrdma-src", "/home/fheinen/leo-cvmrdma-install/br-sev-Release/images"),
]

# SSH control dir
ctl = Path(".ssh_control/")

async def sync_to_host(host_spec):
    """Sync only dotfiles/dot-directories directly to remote host."""
    host, dst_dir, dst_images = host_spec
    ssh_ctl = ctl / "%L-%r@%h:%p"

    # Start SSH session to destination
    print(f"[{host}] Start ssh session")
    p = await asyncio.create_subprocess_exec(
        "ssh",
        "-Nf",
        "-o",
        "ControlMaster=auto",
        "-S",
        str(ssh_ctl),
        "-o",
        "ControlPersist=60",
        host,
    )
    await p.communicate()

    print(f"[{host}] Ensure destination directories exist")
    mkdir_cmd = f"mkdir -p {dst_dir} {dst_images}"
    p = await asyncio.create_subprocess_exec("ssh", "-S", str(ssh_ctl), host, mkdir_cmd)
    await p.communicate()

    # Sync only dotfiles and dot-directories, while excluding buildroot download caches.
    # No --delete: never remove anything on the remote side.
    p = await asyncio.create_subprocess_exec(
        "rsync",
        "-e",
        f"ssh -S {str(ssh_ctl)}",
        "-aPzhv",
        "--prune-empty-dirs",
        "--exclude=cvmrdma-buildroot/dl/***",
        "--include=*/",
        "--include=.*",
        "--include=**/.git/***",
        "--exclude=*",
        "..",
        f"{host}:{dst_dir}",
    )
    await p.communicate()

    print(f"[{host}] Dotfile sync completed")


async def main():
    # Setup SSH control directory
    ctl.mkdir(exist_ok=True)

    # Sync to all remote hosts
    tasks = []
    for host_spec in HOSTS:
        tasks.append(asyncio.create_task(sync_to_host(host_spec)))

    await asyncio.gather(*tasks)

    print("Done")


if __name__ == "__main__":
    asyncio.run(main())
