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

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/cli_root/zfs_presage/zfs_presage.kshlib

#
# DESCRIPTION:
#	zfs_arc_presaged_max_percent has a ceiling: a value above 90 is
#	treated as 90, so that part of the ARC always stays evictable and
#	the ARC can follow its target.
# STRATEGY:
#	1. ARC fixed at 512 MiB, the tunable at 150.  Presage a 768 MiB
#	   file: the request stops with the limit reached.
#	2. presaged_counted is no more than 90 % of the ARC target (plus
#	   one record), and the ARC's size stays within 64 MiB of its
#	   target while a second file is read.
#

verify_runnable "global"

typeset f=$TESTDIR/ce
typeset g=$TESTDIR/ce.other
typeset -i mib=$((1024 * 1024))

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
	rm -f $f $g
}

log_assert "zfs_arc_presaged_max_percent above 90 is treated as 90"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((512 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 150

log_must file_write -o create -f $f -b 1048576 -c 768 -d R
log_must file_write -o create -f $g -b 1048576 -c 256 -d R
sync_pool $TESTPOOL

log_mustnot zfs presage -t 600 $f
typeset -i c=$(kstat arcstats.c)
typeset -i limit=$(kstat arcstats.presaged_limit)
typeset -i counted=$(kstat arcstats.presaged_counted)
log_note "target $c, limit $limit, presaged_counted $counted"
log_must test $limit -eq $((c / 100 * 90))
log_must test $counted -gt $((limit / 10 * 9))
log_must test $counted -le $((limit + mib))

log_must dd if=$g of=/dev/null bs=1M
sleep 2
typeset -i sz=$(kstat arcstats.size)
log_note "ARC size $sz against target $(kstat arcstats.c) after the read"
log_must test $sz -le $(($(kstat arcstats.c) + 64 * mib))

log_must zfs presage -t 0 $f
log_pass "zfs_arc_presaged_max_percent above 90 is treated as 90"
