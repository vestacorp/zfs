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
#	A presage that expires while its blocks are held (by cached dbufs,
#	here) and is then never looked at is demoted when the last hold drops:
#	unmounting the dataset destroys the dbufs, and the header must land on
#	the MFU list exactly once (a second insertion trips
#	VERIFY(!multilist_link_active()) in multilist_insert()).
#

verify_runnable "global"

function cleanup
{
	zfs presage -t 0 $TESTDIR/f >/dev/null 2>&1
	ismounted $TESTPOOL/$TESTFS || log_must zfs mount $TESTPOOL/$TESTFS
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	rm -f $TESTDIR/f
}

log_assert "held presage headers expire cleanly on unmount"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25

typeset -i blocks=64
log_must file_write -o create -f $TESTDIR/f -b 131072 -c $blocks -d R
sync_pool $TESTPOOL
log_must zfs presage -t 3 $TESTDIR/f
log_must test "$(presaged_bytes $TESTDIR/f)" -gt 0
# read it so the dbuf cache holds every block's ARC header
log_must cat $TESTDIR/f > /dev/null

# let it expire with nothing (no status call either) looking at the headers
typeset -i e0=$(kstat arcstats.presaged_expired)
sleep 6
log_must zfs unmount $TESTPOOL/$TESTFS
typeset -i e1=$(kstat arcstats.presaged_expired)
log_must zfs mount $TESTPOOL/$TESTFS
log_must test $((e1 - e0)) -ge $blocks
log_must test "$(presaged_bytes $TESTDIR/f)" -eq 0
log_pass "held presage headers expire cleanly on unmount"
