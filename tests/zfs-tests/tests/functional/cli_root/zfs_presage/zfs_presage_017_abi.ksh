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
#	The ioctl keeps room for fields added later: a non-zero reserved
#	word, an undefined flag bit and the kernel-internal reset bit are
#	refused with EINVAL by the file ioctl, an undefined flag bit by the
#	dataset form, and none of them leaves a reservation behind.  A valid
#	request through each form is the positive control.
#
# STRATEGY:
#	1. Enable presage; write a small file and create a small volume.
#	2. presage_ioctl reserved|flag|internal on the file: EINVAL each
#	   time, and status shows no reservation.
#	3. presage_ioctl lzc_flag on the volume: EINVAL, no reservation.
#	4. The reservation count is back at its baseline.
#	5. presage_ioctl ok on the file and lzc_ok on the volume succeed and
#	   each leaves a reservation; kill both.
#

verify_runnable "global"

typeset vol=$TESTPOOL/$TESTVOL

function cleanup
{
	zfs presage -t 0 $TESTDIR/f >/dev/null 2>&1
	zfs presage -t 0 $vol >/dev/null 2>&1
	datasetexists $vol && log_must zfs destroy $vol
	rm -f $TESTDIR/f
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "non-zero reserved words and unknown flags are EINVAL"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25
typeset -i base=$(kstat presage.reservations)

log_must file_write -o create -f $TESTDIR/f -b 131072 -c 16 -d R
log_must zfs create -V 16m $vol
block_device_wait
sync_pool $TESTPOOL

typeset mode
for mode in reserved flag internal; do
	log_must presage_ioctl $mode $TESTDIR/f
	log_must test "$(expires_at $TESTDIR/f)" -eq 0
	log_must test "$(pending_count $TESTDIR/f)" -eq 0
	log_must test "$(presaged_bytes $TESTDIR/f)" -eq 0
done

log_must presage_ioctl lzc_flag $vol
log_must test "$(expires_at $vol)" -eq 0
log_must test "$(pending_count $vol)" -eq 0
log_must test "$(kstat presage.reservations)" -eq $base

log_must presage_ioctl ok $TESTDIR/f
log_must test "$(expires_at $TESTDIR/f)" -gt 0
log_must test "$(kstat presage.reservations)" -eq $((base + 1))
log_must zfs presage -t 0 $TESTDIR/f
log_must test "$(expires_at $TESTDIR/f)" -eq 0

log_must presage_ioctl lzc_ok $vol
log_must test "$(expires_at $vol)" -gt 0
log_must zfs presage -t 0 $vol
log_must test "$(expires_at $vol)" -eq 0
presage_wait_clean $base

log_pass "non-zero reserved words and unknown flags are EINVAL"
