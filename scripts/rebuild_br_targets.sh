#!/usr/bin/env bash
set -u

if [[ $# -lt 1 ]]; then
  printf "%s BUILD_TYPE <target1> [target2 ...]" "$0"
  printf "Rebuild target1, target2, ...\n";
  exit
fi

BUILD_TYPE="$1"
shift

INSTALL_DIR="$HOME/leo-cvmrdma-install"
BR="$INSTALL_DIR/br-sev-$BUILD_TYPE"


MAKE="make -C $BR"
for TARGET in "$@"; do
  echo "Rebuild $TARGET..."
  set -x
  $MAKE $TARGET-rebuild
  set +x
done;

set -x
$MAKE all
