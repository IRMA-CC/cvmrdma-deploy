#!/usr/bin/env bash
set -u

if [[ $# -lt 1 ]]; then
  printf "%s <target1> [target2 ...]" "$0"
  printf "Rebuild target1, target2, ...\n";
  exit
fi

INSTALL_DIR="$HOME/cvmrdma-install"
BR="$INSTALL_DIR/br-cvm"
shift;

MAKE="make -C $BR"
for TARGET in $@; do
  set -x
  $MAKE $TARGET-rebuild
  set +x
done;

set -x
$MAKE all
