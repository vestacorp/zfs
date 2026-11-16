#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#
# Copyright (c) 2026, Vesta Corporation.
# Copyright (c) 2026, Todd Curry.
#

. $STF_SUITE/tests/functional/cli_root/zfs_presage/zfs_presage.kshlib

#
# DESCRIPTION:
#	A volume can be presaged by name while closed: its data stays resident
#	under cache pressure, status works by name, by -V and by device path,
#	a byte range is honoured, and -t 0 kills.
#
# STRATEGY:
#	1. Enable presage, shrink the ARC to 256M.
#	2. Create a 256M volume, write 64M into its device, close it; write a
#	   1G stream file; sync; export/import to start cold.
#	3. Presage the volume by name for 600s: all 64M reported presaged.
#	4. Status by -V and by /dev/zvol path agree; a 16M sub-range reports
#	   16M.
#	5. Stream 1G through the ARC: the volume is still fully resident.
#	6. Kill by name: nothing presaged.
#

verify_runnable "global"

typeset vol=$TESTPOOL/$TESTVOL
typeset -i mib=$((1024 * 1024))

function cleanup
{
	zfs presage -t 0 $vol >/dev/null 2>&1
	datasetexists $vol && log_must zfs destroy $vol
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
	rm -f $TESTDIR/stream
}

log_assert "zfs presage keeps a closed volume's data resident by name"
log_onexit cleanup

save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
arc_small $((256 * mib))

log_must zfs create -V 256m $vol
block_device_wait
typeset dev=$(presage_zvol_dev $vol)
[[ -n $dev ]] || log_unsupported "no block device for $vol (no udev rules)"
log_must dd if=/dev/urandom of=$dev bs=1M count=64 conv=fsync
log_must file_write -o create -f $TESTDIR/stream -b 1048576 -c 1024 -d R
sync_pool $TESTPOOL
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL

log_must zfs presage -t 600 $vol
log_must test "$(presaged_bytes $vol)" -eq $((64 * mib))
log_must test "$(presaged_bytes "-V $vol")" -eq $((64 * mib))
log_must test "$(presaged_bytes /dev/zvol/$vol)" -eq $((64 * mib))
log_must test "$(presaged_bytes "-o $((32 * mib)) -l $((16 * mib)) $vol")" \
    -eq $((16 * mib))
log_must test "$(pending_count $vol)" -eq 0
log_must test "$(warmed_at $vol)" -gt 0

log_must dd if=$TESTDIR/stream of=/dev/null bs=1M

log_must test "$(presaged_bytes $vol)" -eq $((64 * mib))

log_must zfs presage -t 0 $vol
sleep 2
log_must test "$(presaged_bytes $vol)" -eq 0
log_pass "zfs presage keeps a closed volume's data resident by name"
