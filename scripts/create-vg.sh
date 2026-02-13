#!/bin/bash
# create-vg.sh — Ensure the "myvg1" LVM volume group exists for TopoLVM
#
# On first boot, creates a sparse 10GB loopback file and initialises it as
# an LVM PV + VG.  On subsequent boots, re-attaches the existing file to a
# loop device so the VG is available before MicroShift starts.
set -euo pipefail

VG_NAME="myvg1"
BACKING_FILE="/var/lib/topolvm/backing.img"
BACKING_SIZE="10G"

# Already active — nothing to do
if vgs "${VG_NAME}" &>/dev/null; then
    exit 0
fi

mkdir -p "$(dirname "${BACKING_FILE}")"

# First boot: create the sparse backing file and initialise LVM
if [ ! -f "${BACKING_FILE}" ]; then
    truncate -s "${BACKING_SIZE}" "${BACKING_FILE}"
    LOOP=$(losetup --show -f "${BACKING_FILE}")
    pvcreate "${LOOP}"
    vgcreate "${VG_NAME}" "${LOOP}"
else
    # Subsequent boots: re-attach the existing file
    LOOP=$(losetup --show -f "${BACKING_FILE}")
    vgchange -ay "${VG_NAME}"
fi
