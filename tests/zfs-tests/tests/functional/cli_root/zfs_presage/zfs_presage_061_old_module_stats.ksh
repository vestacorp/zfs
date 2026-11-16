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
#	zarcstat and zarcsummary still work with a module that has no
#	presaged arcstats (new tools before a reboot into the new module).
#	Neither may fail for a statistic the module does not report.
# STRATEGY:
#	1. Copy the live kstat files into $TESTDIR, without any presaged_
#	   line in arcstats.
#	2. Run copies of zarcstat and zarcsummary that read that directory
#	   instead of /proc/spl/kstat/zfs: default output, all fields, the
#	   presaged fields by name, and the full summary.  Each must exit 0
#	   without a Python traceback, and the presaged fields read 0.
#	Linux only: on FreeBSD both tools read sysctl, which a test cannot
#	stand in for.
#

verify_runnable "global"

if ! is_linux; then
	log_unsupported "the tools read sysctl on FreeBSD"
fi

typeset dir=$TESTDIR/oldkstat

function cleanup
{
	rm -rf $dir
}

function run_tool # output-file command...
{
	typeset out=$1
	shift
	"$@" > $out 2>&1
	typeset -i rc=$?
	if (( rc != 0 )) || grep -q Traceback $out; then
		cat $out
		log_fail "$* failed with status $rc"
	fi
	log_note "$* ok"
}

log_assert "zarcstat and zarcsummary work without the presaged arcstats"
log_onexit cleanup

# 1. the kstats of a module without presage
log_must mkdir -p $dir/zfs
for f in /proc/spl/kstat/zfs/*; do
	[[ -f $f ]] || continue
	log_must eval "cat $f > $dir/zfs/${f##*/}"
done
log_must eval "grep -v '^presaged_' /proc/spl/kstat/zfs/arcstats" \
    "> $dir/zfs/arcstats"
log_mustnot grep -q '^presaged_' $dir/zfs/arcstats

# 2. the tools, reading that directory
typeset zarcstat zarcsummary
zarcstat=$(command -v zarcstat) || log_unsupported "no zarcstat"
zarcsummary=$(command -v zarcsummary) || log_unsupported "no zarcsummary"
log_must eval "sed 's|/proc/spl/kstat/zfs|$dir/zfs|g' $zarcstat" \
    "> $dir/zarcstat"
log_must eval "sed 's|/proc/spl/kstat/zfs|$dir/zfs|g' $zarcsummary" \
    "> $dir/zarcsummary"
log_must chmod +x $dir/zarcstat $dir/zarcsummary
log_mustnot grep -q /proc/spl/kstat $dir/zarcstat $dir/zarcsummary

run_tool $dir/out $dir/zarcstat 1 2
run_tool $dir/out $dir/zarcstat -x 1 1
run_tool $dir/out $dir/zarcstat -a 1 1
run_tool $dir/out $dir/zarcstat -p -f psgsz,psgda,psgme,psged,psgem,psg 1 1
log_must test \
    "$(tail -1 $dir/out | awk '{print $1 + $2 + $3 + $4 + $5 + $6}')" -eq 0
run_tool $dir/out $dir/zarcsummary
run_tool $dir/out $dir/zarcsummary -s arc

log_pass "zarcstat and zarcsummary work without the presaged arcstats"
