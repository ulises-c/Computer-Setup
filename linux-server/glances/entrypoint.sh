#!/bin/sh
# Resolves /dev/disk/by-label/ symlinks to current kernel device names and
# monkey-patches the Glances diskio plugin to use persistent label-based names
# (e.g. "Seagate_4TB" instead of "sda"), so Homepage disk I/O widgets survive
# kernel name reordering across reboots.

PYTHON_BIN="/venv/bin/python${PYTHON_VERSION}"

# Build mapping of kernel device name -> label from /dev/disk/by-label/
DISK_MAPPING=""
for link in /dev/disk/by-label/Seagate_4TB /dev/disk/by-label/WD_1TB /dev/disk/by-label/WD14TB; do
    [ -L "$link" ] || continue
    label=$(basename "$link")
    device=$(readlink "$link" | sed 's|.*/||; s/[0-9]*$//')
    [ -n "$device" ] && DISK_MAPPING="${DISK_MAPPING}${device}:${label},"
done
DISK_MAPPING="${DISK_MAPPING%,}"

if [ -n "$DISK_MAPPING" ]; then
    export GLANCES_DISK_MAPPING="$DISK_MAPPING"
    exec $PYTHON_BIN -c "
import sys, os
sys.path.insert(0, '/')
import rename_disks
from glances import main
sys.argv = ['glances']
args = os.environ.get('GLANCES_OPT', '-w').split()
sys.argv.extend(args)
main()
"
else
    exec $PYTHON_BIN -m glances ${GLANCES_OPT:--w}
fi
