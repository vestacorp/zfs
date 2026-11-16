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
#	Two edge cases of a live volume reservation: a volsize shrink under
#	it leaves exactly the surviving range presaged, with no error; and
#	a pool export with it active neither hangs nor leaks a hold: the
#	pool exports at once, after import the volume has no reservation,
#	the presage kstat shows the reservation count back at baseline and
#	no hold held, and the volume can be reserved again and destroyed
#	immediately.
#

verify_runnable "global"

typeset vol=$TESTPOOL/$TESTVOL
typeset -i mib=$((1024 * 1024))

function cleanup
{
	poolexists $TESTPOOL || log_must zpool import $TESTPOOL
	zfs presage -t 0 $vol >/dev/null 2>&1
	datasetexists $vol && log_must zfs destroy $vol
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "volsize shrink and pool export under a live volume reservation"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)

log_must zfs create -V 256m $vol
block_device_wait
typeset dev=$(presage_zvol_dev $vol)
typeset have_data=false
if [[ -n $dev ]]; then
	log_must dd if=/dev/urandom of=$dev bs=1M count=64 conv=fsync
	have_data=true
fi
sync_pool $TESTPOOL

# 1. shrink under an active reservation
log_must zfs presage -t 600 $vol
$have_data && log_must test "$(presaged_bytes $vol)" -eq $((64 * mib))
log_must zfs set volsize=32m $vol
sync_pool $TESTPOOL
sleep 6
log_must zfs presage status $vol
log_must test "$(presaged_bytes $vol)" -le $((32 * mib))
$have_data && log_must test "$(presaged_bytes $vol)" -eq $((32 * mib))
log_must test "$(warmed_at $vol)" -gt 0
log_must test "$(kstat presage.holds)" -eq 0
log_must zfs presage status -o $((48 * mib)) $vol
log_must test "$(presaged_bytes "-o $((48 * mib)) $vol")" -eq 0

# 2. export with the reservation active
log_must zfs presage -s +120s -t 60 -o 0 -l $((1 * mib)) $vol
log_must test "$(pending_count $vol)" -eq 1
log_must test "$(kstat presage.reservations)" -ge 2
log_must zpool export $TESTPOOL
# export drops every reservation on the pool synchronously
presage_wait_clean 0
log_must zpool import $TESTPOOL
log_must test "$(pending_count $vol)" -eq 0
log_must test "$(warmed_at $vol)" -eq 0
log_must test "$(presaged_bytes $vol)" -eq 0
log_must zfs presage -t 60 $vol
log_must test "$(warmed_at $vol)" -gt 0
log_must zfs destroy $vol
log_mustnot zfs presage status $vol
presage_wait_clean $base
log_pass "volsize shrink and pool export under a live volume reservation"
