#!/usr/bin/env bash
# Apply the platform patches to an Android source tree (repo checkout):
#   ./apply-patches.sh /path/to/android-tree
# Each patches/<project path>/*.patch is `git am`ed into that project.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
top=${1:?usage: $0 <android tree>}
cd "$here/patches"
find . -name '*.patch' | sort | while read -r p; do
  proj=$(dirname "${p#./}")
  echo "$proj: $(basename "$p")"
  git -C "$top/$proj" am -q --3way "$here/patches/$p"
done
