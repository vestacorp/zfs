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
#	A rollback made by a channel program (zfs.sync.rollback) does not
#	pass through the rollback ioctl; it releases a presaged volume all
#	the same.
#
# STRATEGY:
#	1. Create a 64 MiB volume, write 32 MiB when a device exists,
#	   presage it and snapshot it: one reservation.
#	2. Roll back with a channel program (retried while the volume is
#	   briefly held open by udev or by a presage sweep: EBUSY).
#	3. Within seconds the reservation count is at its baseline, status
#	   reports no deadline and nothing presaged, and no hold is left.
#

verify_runnable "global"

typeset vol=$TESTPOOL/prszcpvol
typeset -i mib=$((1024 * 1024))

function cleanup
{
	zfs presage -t 0 $vol >/dev/null 2>&1
	datasetexists $vol && log_must zfs destroy -r $vol
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "a channel-program rollback releases a presaged volume"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

# 1. a presaged volume with a snapshot
log_must zfs create -V 64m $vol
block_device_wait
typeset dev=$(presage_zvol_dev $vol)
typeset have_data=false
if [[ -n $dev ]]; then
	log_must dd if=/dev/urandom of=$dev bs=1M count=32 conv=fsync
	have_data=true
fi
sync_pool $TESTPOOL
log_must zfs presage -t 300 $vol
$have_data && log_must test "$(presaged_bytes $vol)" -eq $((32 * mib))
log_must zfs snapshot $vol@s1
log_must test "$(kstat presage.reservations)" -eq $((base + 1))

# 2. rollback by channel program
typeset -i i busy=0
typeset out
for ((i = 0; i < 60; i++)); do
	out=$(echo 'local a = ...
local e = zfs.sync.rollback(a.argv[1])
if e ~= 0 then error("rollback failed: " .. e) end' |
	    zfs program $TESTPOOL - $vol 2>&1) && break
	busy=$((busy + 1))
	sleep 0.5
done
log_note "channel-program rollback: $busy attempts failed first; last: $out"
log_must test $i -lt 60

# 3. released
presage_wait_clean $base
log_must test "$(kstat presage.reservations)" -eq $base
log_must test "$(expires_at $vol)" -eq 0
log_must test "$(presaged_bytes $vol)" -eq 0
log_must test "$(kstat presage.holds)" -eq 0
presage_wait_settled $((psize0 + mib)) 30

log_pass "a channel-program rollback releases a presaged volume"
