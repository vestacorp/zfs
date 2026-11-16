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
#	Residency ends after the TTL; a new request on the same file
#	replaces the old one; -t 0 kills now; the CLI default TTL is 1800s.
#

verify_runnable "global"

function cleanup
{
	zfs presage -t 0 $TESTDIR/f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	rm -f $TESTDIR/f
}

log_assert "zfs presage TTL expiry, replacement, kill and default TTL"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25

log_must file_write -o create -f $TESTDIR/f -b 131072 -c 64 -d R
sync_pool $TESTPOOL

# expiry
log_must zfs presage -t 3 $TESTDIR/f
log_must test "$(presaged_bytes $TESTDIR/f)" -gt 0
sleep 6
log_must test "$(presaged_bytes $TESTDIR/f)" -eq 0
log_must test "$(kstat arcstats.presaged_expired)" -gt 0

# replacement: the later request wins, even if shorter
log_must zfs presage -t 60 $TESTDIR/f
log_must zfs presage -t 2 $TESTDIR/f
sleep 5
log_must test "$(presaged_bytes $TESTDIR/f)" -eq 0

# kill
log_must zfs presage -t 60 $TESTDIR/f
log_must test "$(presaged_bytes $TESTDIR/f)" -gt 0
log_must zfs presage -t 0 $TESTDIR/f
sleep 2
log_must test "$(presaged_bytes $TESTDIR/f)" -eq 0
log_mustnot zfs presage -t 0 $TESTDIR/f

# default TTL
typeset now=$(date +%s)
log_must zfs presage $TESTDIR/f
typeset exp=$(expires_at $TESTDIR/f)
log_must test $((exp - now)) -ge 1790
log_must test $((exp - now)) -le 1810
log_must zfs presage -t 0 $TESTDIR/f
log_pass "zfs presage TTL expiry, replacement, kill and default TTL"
