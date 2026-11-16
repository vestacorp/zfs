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
#	zfs presage refuses malformed arguments before it asks the kernel,
#	and says why: a duration that overflows must not wrap to a small
#	TTL, a start time with trailing characters must not be taken for
#	its prefix, and -o and -l take a number and nothing else.
# STRATEGY:
#	1. Well-formed durations, starts, offsets and lengths work.
#	2. Malformed or overflowing durations are refused as invalid TTLs.
#	3. Malformed starts are refused as invalid start times.
#	4. Malformed offsets and lengths are refused.
#	5. A TTL over 30 days, or a start more than 30 days ahead, is
#	   refused with a message that says so; 30 days exactly is fine.
#	   No reservation is left by any refused request.
#	6. A volume name that does not exist gets "no such volume", on a
#	   kill too; a filesystem named as a volume gets "not a volume".
#	7. A directory is refused by the command and, through
#	   presage_ioctl, by the kernel with EISDIR (21 on Linux and
#	   FreeBSD); a FIFO is refused as not a regular file.
#

verify_runnable "global"

typeset f=$TESTDIR/prsargs
typeset out=$TESTDIR/prsargs.out
typeset dir=$TESTDIR/prsargs.dir
typeset fifo=$TESTDIR/prsargs.fifo

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	rm -f $f $out $fifo
	rm -rf $dir
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

# Run zfs presage with the given arguments; it must fail, and its error
# output must match the pattern.
function refused # pattern args...
{
	typeset pattern=$1
	shift
	zfs presage "$@" > $out 2>&1
	typeset -i rc=$?
	if (( rc == 0 )); then
		cat $out
		log_fail "zfs presage $* was accepted"
	fi
	if ! grep -q -- "$pattern" $out; then
		cat $out
		log_fail "zfs presage $* failed without '$pattern'"
	fi
	log_note "zfs presage $* refused: $(head -1 $out)"
}

log_assert "zfs presage refuses malformed and out-of-range arguments"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25
typeset -i base=$(kstat presage.reservations)

log_must file_write -o create -f $f -b 131072 -c 16 -d R
sync_pool $TESTPOOL

# 1. well-formed arguments
for ttl in 60 90s 5m 2h 1d 30d 2592000; do
	log_must zfs presage -t $ttl $f
done
log_must zfs presage -t 0 $f
log_must zfs presage -t 60 -o 0 -l 131072 $f
log_must zfs presage -t 60 -o 0x20000 -l 0x20000 $f
log_must zfs presage -t 0 $f
log_must zfs presage -s +30d -t 60 $f
log_must zfs presage -s +1h -t 60 $f
log_must zfs presage -s 23:59 -t 60 $f
log_must zfs presage -t 0 $f
presage_wait_clean $base

# 2. durations: a sign, a space, a bad unit, text after the unit, and
# values that overflowed (213503982334602d wrapped to 61184 s and was
# accepted; 18446744073709551615 is the old error value itself)
for ttl in -5 +5 " 5" "" s 5x 5mm 5m5 1.5h 0x10 \
    213503982334602d 307445734561825861m 18446744073709551615 \
    99999999999999999999; do
	refused "invalid TTL" -t "$ttl" $f
done

# 3. starts: trailing characters after each form, signs, overflow
for start in 10:3x 1:30x 12:34: "+" +-5 "+ 5" +5x -5 " 5" 5x \
    99999999999999999999 +213503982334602d; do
	refused "invalid start time" -s "$start" -t 60 $f
done

# 4. offsets and lengths
for n in "" -1 +1 " 1" 12abc 1k 0x 0xg 08 99999999999999999999999; do
	refused "invalid offset" -t 60 -o "$n" $f
	refused "invalid length" -t 60 -l "$n" $f
done

# 5. the 30-day limits
refused "at most 30 days" -t 31d $f
refused "at most 30 days" -t 2592001 $f
refused "at most 30 days" -t 721h $f
refused "at most 30 days ahead" -s +31d -t 60 $f
refused "at most 30 days ahead" -s +2592060 -t 60 $f
log_must test "$(kstat presage.reservations)" -eq $base

# 6. a volume name that does not exist is reported as such, also on a
# kill (not as "nothing to kill"), and a filesystem given
# as a volume is not a volume
typeset novol=$TESTPOOL/prs-no-such-volume
for name in /dev/zvol/$novol "-V $novol"; do
	refused "no such volume" -t 60 $name
	refused "no such volume" -t 0 $name
	refused "no such volume" status $name
done
log_mustnot eval "zfs presage -t 0 /dev/zvol/$novol 2>&1 |" \
    "grep -q 'nothing to kill'"
refused "not a volume" -t 60 /dev/zvol/$TESTPOOL/$TESTFS
refused "not a volume" -t 0 -V $TESTPOOL/$TESTFS

# 7. a directory is refused by the command and by the kernel (which used
# to take its entry count for a size); so is any other non-regular file
log_must mkdir $dir
log_must mkfifo $fifo
refused "is a directory" -t 60 $dir
refused "is a directory" -t 0 $dir
refused "is a directory" status $dir
refused "not a regular file" -t 60 $fifo
log_mustnot presage_ioctl ok $dir
log_must eval "presage_ioctl ok $dir 2>/dev/null | grep -qx errno=21"
log_must test "$(kstat presage.reservations)" -eq $base

log_pass "zfs presage refuses malformed and out-of-range arguments"
