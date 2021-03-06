#! /usr/bin/env sh
#
# Copyright (c) 2013 Antti Kantee <pooka@iki.fi>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#

#
# scrub necessary parts of the env
unset BUILDRUMP_CPPCACHE

# defaults, can be overriden by probes
RUMP_VIRTIF=no
HIJACK=false
SYS_SUNOS=false

#
# support routines
#

helpme ()
{

	echo "Usage: $0 [-h] [options] [command] [command...]"
	printf "supported options:\n"
	printf "\t-d: location for headers/libs.  default: PWD/rump\n"
	printf "\t-o: location for build-time files.  default: PWD/obj\n"
	printf "\t-T: location for tools+rumpmake.  default: PWD/obj/tooldir\n"
	printf "\t-s: location of source tree.  default: PWD/src\n"
	echo
	printf "\t-j: value of -j specified to make.  default: ${JNUM}\n"
	printf "\t-q: quiet build, less compiler output.  default: noisy\n"
	printf "\t-r: release build (no -g, DIAGNOSTIC, etc.).  default: no\n"
	printf "\t-D: increase debugginess.  default: -O2 -g\n"
	printf "\t-k: only kernel components (no hypercalls).  default: all\n"
	printf "\t-N: emulate NetBSD, set -D__NetBSD__ etc.  default: no\n"
	echo
	printf "\t-H: ignore diagnostic checks (expert-only).  default: no\n"
	printf "\t-V: specify -V arguments to NetBSD build (expert-only)\n"
	printf "\t-F: specify build flags with -F XFLAGS=value\n"
	printf "\t    possible values for XFLAGS:\n"
	printf "\t    CFLAGS, AFLAGS, LDFLAGS, ACFLAGS, ACLFLAGS,"
	printf "\t    CPPFLAGS, DBG\n"
	echo
	printf "supported commands (default => checkout+fullbuild+tests):\n"
	printf "\tcheckoutgit:\tfetch NetBSD sources to srcdir from github\n"
	printf "\tcheckoutcvs:\tfetch NetBSD sources to srcdir from anoncvs\n"
	printf "\tcheckout:\talias for checkoutgit\n"
	printf "\ttools:\t\tbuild necessary tools to tooldir\n"
	printf "\tbuild:\t\tbuild everything related to rump kernels\n"
	printf "\tinstall:\tinstall rump kernel components into destdir\n"
	printf "\ttests:\t\trun tests to verify installation is functional\n"
	printf "\tfullbuild:\talias for \"tools build install\"\n"
	exit 1
}

#
# toolchain creation helper routines
#

printoneconfig ()
{

	[ -z "${2}" ] || printf "%-5s %-18s: %s\n" "${1}" "${2}" "${3}"
}

printenv ()
{

	# XXX: this is not yet functional the way I want it to be
	echo '>> Build environment (from shell)'
	printoneconfig 'Env' 'BUILDRUMP_CPPFLAGS' "${BUILDRUMP_CPPFLAGS}"
	printoneconfig 'Env' 'BUILDRUMP_CFLAGS' "${BUILDRUMP_CFLAGS}"
	printoneconfig 'Env' 'BUILDRUMP_AFLAGS' "${BUILDRUMP_AFLAGS}"
	printoneconfig 'Env' 'BUILDRUMP_LDFLAGS' "${BUILDRUMP_LDFLAGS}"
}

appendmkconf ()
{
	if [ ! -z "${2}" ]; then
		# cheat a bit: output BUILDRUMP_CFLAGS/AFLAGS without
		# the prefix as the name so to as not confuse the user
		# (the reason why it's BUILDRUMP_CFLAGS instead of
		# CFLAGS is so that we get the flags right for
		# the RUMPCOMP_USER case)
		case $3 in
		'BUILDRUMP_CFLAGS'|'BUILDRUMP_AFLAGS')
			name=${3#BUILDRUMP_}
			;;
		*)
			name=${3}
		esac

		val=${2# }
		printoneconfig "${1}" "${name}" "${val}"
		echo "${3}${4}=${val}" >> "${MKCONF}"
	fi
}

appendvar ()
{

	vname=${1}
	shift
	eval ${vname}="\"\${${vname}} \${*}\""
}

#
# Not all platforms have  the same set of crt files.  for some
# reason unbeknownst to me, if the file does not exist,
# at least gcc --print-file-name just echoes the input parameter.
# Try to detect this and tell the NetBSD makefiles that the crtfile
# in question should be left empty.
chkcrt ()
{
	tst=`${CC} --print-file-name=crt${1}.o`
	up=`echo ${1} | tr [a-z] [A-Z]`
	[ -z "${tst%crt${1}.o}" ] \
	    && echo "_GCC_CRT${up}=" >>"${MKCONF}"
}

probeld ()
{

	linkervers=$(${CC} ${EXTRA_LDFLAGS} -Wl,--version 2>&1)
	if echo ${linkervers} | grep -q 'GNU ld' ; then
		LD_FLAVOR=GNU
		LD_AS_NEEDED='-Wl,--no-as-needed'
	elif echo ${linkervers} | grep -q 'GNU gold' ; then
		LD_FLAVOR=gold
		LD_AS_NEEDED='-Wl,--no-as-needed'
	elif echo ${linkervers} | grep -q 'Solaris Link Editor' ; then
		LD_FLAVOR=sun
		SHLIB_MKMAP=no
	else
		echo '>> output from linker:'
		echo ${linkervers}
		die 'GNU or Solaris ld required'
	fi

	# Check if the linker supports all the features of the rump kernel
	# component ldscript used for linking shared libraries.
	if [ ! ${LD_FLAVOR} = 'sun' ]; then
		echo 'SECTIONS { } INSERT AFTER .data' > ldscript.test
		doesitbuild 'int main(void) {return 0;}' -Wl,-T,ldscript.test
		if [ $? -ne 0 ]; then
			if ${KERNONLY} || [ "${MKPIC}" = "no" ]; then
				LDSCRIPT='no'
			else
				LDSCRIPT='ctor'
			fi
		fi
		rm -f ldscript.test
	else
		LDSCRIPT='sun'
	fi
}

# Check if $NM outputs the format we except, i.e. if symbols
# are the alone in the last whitespace-separated column.
# GNU and OpenBSD nm do this, e.g. Solaris does not.
probenm ()
{

	echo 'void testsym(void); void testsym(void) {return;}' \
	    | ${CC} ${EXTRA_CFLAGS} -x c -c - -o ${OBJDIR}/probenm.o
	lastfield=$(${NM} -go ${OBJDIR}/probenm.o | awk '/testsym/{print $NF}')
	if [ "${lastfield}" != 'testsym' ]; then
		echo nm: expected \"testsym\", got \"${lastfield}\"
		die incompatible output from probing \"${NM}\"
	fi
	rm -f ${OBJDIR}/probenm.o
}

# For ar, we just check the --version.  Works so far.  If it breaks,
# need to start building archives ...
probear ()
{

	# Check for GNU/BSD ar
	if ! ${AR} -V 2>/dev/null | egrep '(GNU|BSD) ar' > /dev/null ; then
		die Need GNU or BSD ar "(`type ${AR}`)"
	fi
}

# check if cpp defines the given parameter (with any value)
cppdefines ()
{

	[ -z "${BUILDRUMP_CPPCACHE}" ] \
	    && BUILDRUMP_CPPCACHE=$(${CC} ${EXTRA_CFLAGS}	\
		-E -Wp,-dM - < /dev/null)
	var=${1}
	(
	    IFS=' '
	    echo ${BUILDRUMP_CPPCACHE} | awk '$2 == "'$var'"{exit 37}'
	    exit $?
	)
	[ $? -eq 37 ]
	return
}

# check if C snippet given as first argument will build
# arguments [2..n] are passed to the compiler
doesitbuild ()
{

	theprog="${1}"
	shift

	warnflags="-Wmissing-prototypes -Wstrict-prototypes -Wimplicit -Werror"
	printf "${theprog}" \
	    | ${CC} ${warnflags} ${EXTRA_LDFLAGS} ${EXTRA_CFLAGS}	\
		-x c - -o /dev/null $* > /dev/null 2>&1
}

checkcheckout ()
{

	[ -x "${SRCDIR}/build.sh" ] || die "Cannot find ${SRCDIR}/build.sh!"

	[ ! -z "${TARBALLMODE}" ] && return

	if ! ${BRDIR}/checkout.sh checkcheckout ${SRCDIR} \
	    && ! ${TITANMODE}; then
		die 'revision mismatch, run checkout (or -H to override)'
	fi
}

checkcompiler ()
{

	if ! ${KERNONLY}; then
		doesitbuild 'int main(void) {return 0;}\n' \
		    ${EXTRA_RUMPUSER} ${EXTRA_RUMPCOMMON}
		[ $? -eq 0 ] || ${TITANMODE} || \
		    die 'Probe cannot build a binary'
	fi
}

probe_rumpuserbits ()
{

	# Do we need -lrt for time related stuff?
	# Old glibc and Solaris need it, but newer glibc and most
	# other systems do not need or have librt.
	for l in '' '-lrt' ; do
		doesitbuild '#include <time.h>\n
		    int main(void) {
			struct timespec ts;
			return clock_gettime(CLOCK_REALTIME, &ts);}' $l
		if [ $? -eq 0 ]; then
			EXTRA_RUMPUSER="$l"
			break
		fi
	done

	# is it a source tree which comes with autoconf?  if so, prefer that
	if [ -x ${SRCDIR}/lib/librumpuser/configure ]; then
		echo '>> librumpuser configure script detected.  running'
		echo '>>'
		mkdir -p ${BRTOOLDIR}/autoconf
		( export CFLAGS="${EXTRA_CFLAGS}"
		  export LDFLAGS="${EXTRA_LDFLAGS}"
		  export CPPFLAGS="${EXTRA_CPPFLAGS}"
		  cd ${BRTOOLDIR}/autoconf \
		    && ${SRCDIR}/lib/librumpuser/configure \
		      $( ! ${NATIVEBUILD} && echo --host ${CC_TARGET} ) )
		[ $? -eq 0 ] || die configure script failed

		echo "CPPFLAGS+=-DRUMPUSER_CONFIG=yes" >> "${MKCONF}"
		echo "CPPFLAGS+=-I${BRTOOLDIR}/autoconf" >> "${MKCONF}"
		return 0
	fi

	#
	# else, homegrown autoconf for old source trees
	#

	#
	# Check if the target supports posix_memalign()
	doesitbuild \
	    '#include <stdlib.h>
		void *m;int main(void){posix_memalign(&m,0,0);return 0;}\n'
	[ $? -eq 0 ] && POSIX_MEMALIGN='-DHAVE_POSIX_MEMALIGN'

	doesitbuild \
	    '#include <sys/ioctl.h>\n#include <unistd.h>\n
	    int ioctl(int fd, int cmd, ...); int main(void) {return 0;}\n'
	[ $? -eq 0 ] && IOCTL_CMD_INT='-DHAVE_IOCTL_CMD_INT'

	# two or three-arg pthread_setname_np().  or none?
	doesitbuild '#define _GNU_SOURCE\n#include <pthread.h>\n
	    int main(void) {
		pthread_t pt; pthread_setname_np(pt, "jee", 0);return 0;}' -c
	[ $? -eq 0 ] && PTHREAD_SETNAME_NP='-DHAVE_PTHREAD_SETNAME_3'
	doesitbuild '#define _GNU_SOURCE\n#include <pthread.h>\n
	    int main(void) {
		pthread_t pt; pthread_setname_np(pt, "jee");return 0;}' -c
	[ $? -eq 0 ] && PTHREAD_SETNAME_NP='-DHAVE_PTHREAD_SETNAME_2'
}

#
# Create tools and wrappers.  This step needs to be run at least once.
# The routine is run if the "tools" argument is specified.
#
# You might want to skip it because:
# 1) iteration speed on a slow-ish host
# 2) making manual modifications to the tools for testing and avoiding
#    the script nuking them on the next iteration
#
# external toolchain links are created in the format that
# build.sh expects.
#
maketools ()
{

	checkcheckout

	# Check for ld because we need to make some adjustments based on it
	probeld
	probenm
	probear

	cd ${OBJDIR}

	# Create mk.conf.  Create it under a temp name first so as to
	# not affect the tool build with its contents
	MKCONF="${BRTOOLDIR}/mk.conf.building"
	> "${MKCONF}"
	mkconf_final="${BRTOOLDIR}/mk.conf"
	> ${mkconf_final}

	${KERNONLY} || probe_rumpuserbits

	checkcompiler

	#
	# Create external toolchain wrappers.
	mkdir -p ${BRTOOLDIR}/bin || die "cannot create ${BRTOOLDIR}/bin"
	for x in CC AR NM OBJCOPY; do
		# ok, it's not really --netbsd, but let's make-believe!
		if [ ${x} = CC ]; then
			lcx=${CC_FLAVOR}
		else
			lcx=$(echo ${x} | tr '[A-Z]' '[a-z]')
		fi
		tname=${BRTOOLDIR}/bin/${MACH_ARCH}--netbsd${TOOLABI}-${lcx}

		eval tool=\${${x}}
		type ${tool} >/dev/null 2>&1 \
		    || die Cannot find \$${x} at \"${tool}\".
		printoneconfig 'Tool' "${x}" "${tool}"

		exec 3>&1 1>${tname}
		printf '#!/bin/sh\n\n'

		# Make the compiler wrapper mangle arguments suitable for ld.
		# Messy to plug it in here, but ...
		if [ ${x} = 'CC' -a ${LD_FLAVOR} = 'sun' ]; then
			printf 'for x in $*; do\n'
			printf '\t[ "$x" = "-Wl,-x" ] && continue\n'
			printf '\tnewargs="${newargs} $x"\n'
			printf 'done\nexec %s ${newargs}\n' ${tool}
		else
			printf 'exec %s "$@"\n' ${tool}
		fi
		exec 1>&3 3>&-
		chmod 755 ${tname}
	done
	# create a cpp wrapper, but run it via cc -E
	if [ "${CC_FLAVOR}" = 'clang' ]; then
		tname=${BRTOOLDIR}/bin/${MACH_ARCH}--netbsd${TOOLABI}-clang-cpp
	else
		tname=${BRTOOLDIR}/bin/${MACH_ARCH}--netbsd${TOOLABI}-cpp
	fi
	printf '#!/bin/sh\n\nexec %s -E -x c "${@}"\n' ${CC} > ${tname}
	chmod 755 ${tname}

	# Create bounce directory used as the install target.  The
	# purpose of this is to strip the "usr/" pathname component
	# that is hardcoded by NetBSD Makefiles.
	mkdir -p ${BRTOOLDIR}/dest || die "cannot create ${BRTOOLDIR}/dest"
	rm -f ${BRTOOLDIR}/dest/usr
	ln -s ${DESTDIR} ${BRTOOLDIR}/dest/usr

	cat >> "${MKCONF}" << EOF
.if \${BUILDRUMP_SYSROOT:Uno} == "yes"
BUILDRUMP_CPPFLAGS=--sysroot=\${BUILDRUMP_STAGE}
.else
BUILDRUMP_CPPFLAGS=${EXTRA_CPPFLAGS} -I\${BUILDRUMP_STAGE}/usr/include
.endif
LIBDO.pthread=_external
INSTPRIV=-U
AFLAGS+=-Wa,--noexecstack
MKPROFILE=no
MKARZERO=no
USE_SSP=no
MKHTML=no
MKCATPAGES=yes
MKNLS=no
RUMP_NPF_TESTING?=no
RUMPRUN=yes
EOF

	if ! ${KERNONLY}; then
		# queue.h is not available on all systems, but we need it for
		# the hypervisor build.  So, we make it available in tooldir.
		mkdir -p ${BRTOOLDIR}/compat/include/sys \
		    || die create ${BRTOOLDIR}/compat/include/sys
		cp -p ${SRCDIR}/sys/sys/queue.h ${BRTOOLDIR}/compat/include/sys
		echo "CPPFLAGS+=-I${BRTOOLDIR}/compat/include" >> "${MKCONF}"
	fi

	printoneconfig 'Cmd' "SRCDIR" "${SRCDIR}"
	printoneconfig 'Cmd' "DESTDIR" "${DESTDIR}"
	printoneconfig 'Cmd' "OBJDIR" "${OBJDIR}"
	printoneconfig 'Cmd' "BRTOOLDIR" "${BRTOOLDIR}"

	appendmkconf 'Cmd' "${RUMP_DIAGNOSTIC}" "RUMP_DIAGNOSTIC"
	appendmkconf 'Cmd' "${RUMP_DEBUG}" "RUMP_DEBUG"
	appendmkconf 'Cmd' "${RUMP_LOCKDEBUG}" "RUMP_LOCKDEBUG"
	appendmkconf 'Cmd' "${DBG}" "DBG"
	printoneconfig 'Cmd' "make -j[num]" "-j ${JNUM}"

	if ${KERNONLY}; then
		appendmkconf Cmd yes RUMPKERN_ONLY
	fi

	if ${NATIVENETBSD} && ! cppdefines __NetBSD__; then
		appendmkconf 'Cmd' '-D__NetBSD__' 'CPPFLAGS' +
		appendmkconf 'Probe' "${RUMPKERN_UNDEF}" 'CPPFLAGS' +
	else
		appendmkconf 'Probe' "${RUMPKERN_UNDEF}" "RUMPKERN_UNDEF"
	fi
	appendmkconf 'Probe' "${POSIX_MEMALIGN}" "CPPFLAGS" +
	appendmkconf 'Probe' "${IOCTL_CMD_INT}" "CPPFLAGS" +
	appendmkconf 'Probe' "${PTHREAD_SETNAME_NP}" "CPPFLAGS" +
	appendmkconf 'Probe' "${RUMP_CURLWP}" 'RUMP_CURLWP' ?
	appendmkconf 'Probe' "${CTASSERT}" "CPPFLAGS" +
	appendmkconf 'Probe' "${RUMP_VIRTIF}" "RUMP_VIRTIF"
	appendmkconf 'Probe' "${EXTRA_CWARNFLAGS}" "CWARNFLAGS" +
	appendmkconf 'Probe' "${EXTRA_LDFLAGS}" "LDFLAGS" +
	appendmkconf 'Probe' "${EXTRA_CPPFLAGS}" "CPPFLAGS" +
	appendmkconf 'Probe' "${EXTRA_CFLAGS}" "BUILDRUMP_CFLAGS"
	appendmkconf 'Probe' "${EXTRA_AFLAGS}" "BUILDRUMP_AFLAGS"
	unset _tmpvar
	for x in ${EXTRA_RUMPUSER} ${EXTRA_RUMPCOMMON}; do
		appendvar _tmpvar "${x#-l}"
	done
	appendmkconf 'Probe' "${_tmpvar}" "RUMPUSER_EXTERNAL_DPLIBS" +
	unset _tmpvar
	for x in ${EXTRA_RUMPCLIENT} ${EXTRA_RUMPCOMMON}; do
		appendvar _tmpvar "${x#-l}"
	done
	appendmkconf 'Probe' "${_tmpvar}" "RUMPCLIENT_EXTERNAL_DPLIBS" +
	appendmkconf 'Probe' "${LDSCRIPT}" "RUMP_LDSCRIPT"
	appendmkconf 'Probe' "${SHLIB_MKMAP}" 'SHLIB_MKMAP'
	appendmkconf 'Probe' "${SHLIB_WARNTEXTREL}" "SHLIB_WARNTEXTREL"
	appendmkconf 'Probe' "${MKSTATICLIB}"  "MKSTATICLIB"
	appendmkconf 'Probe' "${MKPIC}"  "MKPIC"
	appendmkconf 'Probe' "${MKSOFTFLOAT}"  "MKSOFTFLOAT"

	printoneconfig 'Mode' "${TARBALLMODE}" 'yes'

	printenv

	chkcrt begins
	chkcrt ends
	chkcrt i
	chkcrt n

	# add vars from env last (so that they can be used for overriding)
	cat >> "${MKCONF}" << EOF
CPPFLAGS+=\${BUILDRUMP_CPPFLAGS}
CFLAGS+=\${BUILDRUMP_CFLAGS}
AFLAGS+=\${BUILDRUMP_AFLAGS}
LDFLAGS+=\${BUILDRUMP_LDFLAGS}
EOF

	if ! ${KERNONLY}; then
		echo >> "${MKCONF}"
		cat >> "${MKCONF}" << EOF
# Support for NetBSD Makefiles which use <bsd.prog.mk>
# It's mostly a question of erasing dependencies that we don't
# expect to see
.ifdef PROG
LIBCRT0=
LIBCRTBEGIN=
LIBCRTEND=
LIBCRTI=
LIBC=

LDFLAGS+= -L\${BUILDRUMP_STAGE}/usr/lib -Wl,-R${DESTDIR}/lib
LDADD+= ${EXTRA_RUMPCOMMON} ${EXTRA_RUMPUSER} ${EXTRA_RUMPCLIENT}
EOF
		appendmkconf 'Probe' "${LD_AS_NEEDED}" LDFLAGS +
		echo '.endif # PROG' >> "${MKCONF}"
	fi

	# skip the zlib tests run by "make tools", since we don't need zlib
	# and it's only required by one tools autoconf script.  Of course,
	# the fun bit is that autoconf wants to use -lz internally,
	# so we provide some foo which macquerades as libz.a.
	export ac_cv_header_zlib_h=yes
	echo 'int gzdopen(int); int gzdopen(int v) { return 0; }' > fakezlib.c
	${HOST_CC} -o libz.a -c fakezlib.c
	rm -f fakezlib.c

	# Run build.sh.  Use some defaults.
	# The html pages would be nice, but result in too many broken
	# links, since they assume the whole NetBSD man page set to be present.
	cd ${SRCDIR}

	# create user-usable wrapper script
	makemake ${BRTOOLDIR}/rumpmake ${BRTOOLDIR}/dest makewrapper

	# create wrapper script to be used during buildrump.sh, plus tools
	makemake ${RUMPMAKE} ${OBJDIR}/dest.stage tools

	unset ac_cv_header_zlib_h

	# tool build done.  flip mk.conf name so that it gets picked up
	omkconf="${MKCONF}"
	MKCONF="${mkconf_final}"
	mv "${omkconf}" "${MKCONF}"
	unset omkconf mkconf_final
}

makemake ()
{

	wrapper=$1
	stage=$2
	cmd=$3

	env CFLAGS= HOST_LDFLAGS=-L${OBJDIR} ./build.sh \
	    -m ${MACHINE} -u \
	    -D ${stage} -w ${wrapper} \
	    -T ${BRTOOLDIR} -j ${JNUM} \
	    ${LLVM} ${PCC} ${BEQUIET} \
	    -E -Z S \
	    -V EXTERNAL_TOOLCHAIN=${BRTOOLDIR} -V TOOLCHAIN_MISSING=yes \
	    -V TOOLS_BUILDRUMP=yes \
	    -V MKGROFF=no \
	    -V MKLINT=no \
	    -V MKZFS=no \
	    -V MKDYNAMICROOT=no \
	    -V TOPRUMP="${SRCDIR}/sys/rump" \
	    -V MAKECONF="${mkconf_final}" \
	    -V MAKEOBJDIR="\${.CURDIR:C,^(${SRCDIR}|${BRDIR}),${OBJDIR},}" \
	    -V BUILDRUMP_STAGE=${stage} \
	    ${BUILDSH_VARGS} \
	${cmd}
	[ $? -ne 0 ] && die build.sh ${cmd} failed
}

makebuild ()
{

	checkcheckout

	# ensure we're in SRCDIR, in case "tools" wasn't run
	cd ${SRCDIR}

	printenv

	targets="obj includes dependall install"

	#
	# Building takes 4 passes, just like when
	# building NetBSD the regular way.  The passes are:
	# 1) obj
	# 2) includes
	# 3) dependall
	# 4) install
	#

	DIRS_first='lib/librumpuser'
	DIRS_second='lib/librump'
	DIRS_third="lib/librumpdev lib/librumpnet lib/librumpvfs
	    sys/rump/dev sys/rump/fs sys/rump/kern sys/rump/net
	    sys/rump/include ${BRDIR}/brlib"

	# sys/rump/share was added to ${SRCDIR} 11/2014
	[ -d ${SRCDIR}/sys/rump/share ] \
	    && appendvar DIRS_second ${SRCDIR}/sys/rump/share

	if [ ${MACHINE} = "i386" -o ${MACHINE} = "amd64" \
	     -o ${MACHINE} = "evbearm-el" -o ${MACHINE} = "evbearm-eb" \
	     -o ${MACHINE} = "evbppc" -o ${MACHINE} = "evbppc64" ]; then
		DIRS_emul=sys/rump/kern/lib/libsys_linux
	fi
	${SYS_SUNOS} && appendvar DIRS_emul sys/rump/kern/lib/libsys_sunos
	${HIJACK} && DIRS_final="lib/librumphijack"

	DIRS_third="${DIRS_third} ${DIRS_emul}"

	if ${KERNONLY}; then
		mkmakefile ${OBJDIR}/Makefile.all \
		    sys/rump ${DIRS_emul} ${BRDIR}/brlib
	else
		DIRS_third="lib/librumpclient ${DIRS_third}"

		mkmakefile ${OBJDIR}/Makefile.first ${DIRS_first}
		mkmakefile ${OBJDIR}/Makefile.second ${DIRS_second}
		mkmakefile ${OBJDIR}/Makefile.third ${DIRS_third}
		mkmakefile ${OBJDIR}/Makefile.final ${DIRS_final}
		mkmakefile ${OBJDIR}/Makefile.all \
		    ${DIRS_first} ${DIRS_second} ${DIRS_third} ${DIRS_final}
	fi

	# try to minimize the amount of domake invocations.  this makes a
	# difference especially on systems with a large number of slow cores
	for target in ${targets}; do
		if [ ${target} = "dependall" ] && ! ${KERNONLY}; then
			domake ${OBJDIR}/Makefile.first ${target}
			domake ${OBJDIR}/Makefile.second ${target}
			domake ${OBJDIR}/Makefile.third ${target}
			domake ${OBJDIR}/Makefile.final ${target}
		else
			domake ${OBJDIR}/Makefile.all ${target}
		fi
	done

	if ! ${KERNONLY}; then
		mkmakefile ${OBJDIR}/Makefile.utils \
		    usr.bin/rump_server usr.bin/rump_allserver \
		    usr.bin/rump_wmd
		for target in ${targets}; do
			domake ${OBJDIR}/Makefile.utils ${target}
		done
	fi
}

makeinstall ()
{

	# ensure we run this in a directory that does not have a
	# Makefile that could confuse rumpmake
	stage=$(cd ${BRTOOLDIR} && ${RUMPMAKE} -V '${BUILDRUMP_STAGE}')
	(cd ${stage}/usr ; tar -cf - .) | (cd ${DESTDIR} ; tar -xf -)
}

#
# install kernel headers.
# Note: Do _NOT_ do this unless you want to install a
#       full rump kernel application stack
#  
makekernelheaders ()
{

	dodirs=$(cd ${SRCDIR}/sys && \
	    ${RUMPMAKE} -V '${SUBDIR:Narch:Nmodules:Ncompat:Nnetnatm}' includes)
	# missing powerpc and mips
	appendvar dodirs arch/amd64/include arch/i386/include arch/x86/include
	appendvar dodirs arch/arm/include arch/arm/include/arm32
	for dir in ${dodirs}; do
		(cd ${SRCDIR}/sys/${dir} && ${RUMPMAKE} obj)
		(cd ${SRCDIR}/sys/${dir} && ${RUMPMAKE} includes)
	done
	# create machine symlink
	(cd ${SRCDIR}/sys/arch && ${RUMPMAKE} NOSUBDIR=1 includes)
}

evaltoolchain ()
{

	# is the compiler which targets the host "cc" or something else
	: ${HOST_CC:=cc}
	type ${HOST_CC} >/dev/null 2>&1 \
	    || die set '${HOST_CC}' to a host targeted cc "(now \"${HOST_CC}\")"

	# target compiler
	: ${CC:=cc}
	type ${CC} > /dev/null 2>&1 \
	    || die cannot find \$CC: \"${CC}\".  check env.

	# check for crossbuild
	if ${KERNONLY}; then
		NATIVEBUILD=false
	else
		printf 'int main(void) { return 0; }' \
		    | ${CC} ${EXTRA_CFLAGS} ${EXTRA_LDFLAGS} -x c - \
			-o ${OBJDIR}/canrun > /dev/null 2>&1
		[ $? -eq 0 ] && ${OBJDIR}/canrun
		if [ $? -eq 0 ]; then
			NATIVEBUILD=true
		else
			NATIVEBUILD=false
		fi
		rm -f ${OBJDIR}/canrun
	fi

	# Check for variant of compiler.
	# XXX: why can't all cc's that are gcc actually tell me
	#      that they're gcc with cc --version?!?
	ccver=$(${CC} --version)
	if echo ${ccver} | grep -q 'Free Software Foundation'; then
		CC_FLAVOR=gcc
	elif echo ${ccver} | grep -q clang; then
		CC_FLAVOR=clang
		LLVM='-V HAVE_LLVM=1'
	elif echo ${ccver} | grep -q pcc; then
		CC_FLAVOR=pcc
		PCC='-V HAVE_PCC=1'
	else
		die Unsupported \${CC} "(`type ${CC}`)"
	fi

	# Check the arch we're building for so as to work out the necessary
	# NetBSD machine code we need to use.  First try -dumpmachine,
	# and if that works, be happy with it.  Not all compilers support
	# it (e.g. older versions of clang), so if that doesn't work,
	# try parsing the output of -v
	if ! CC_TARGET=$(${CC} -dumpmachine 2>/dev/null) ; then
		# first check "${CC} -v" ... just in case it fails, we want a
		# sensible return value instead of it being lost in the pipeline
		# (this is easier than adjusting IFS)
		if ${CC} -v >/dev/null 2>&1 ; then
			# then actually process the output of ${CC} -v
			CC_TARGET=$(LC_ALL=C ${CC} -v 2>&1 \
			    | sed -n 's/^Target: //p' )
			[ -z "${CC_TARGET}" ] \
			    && die failed to probe target of \"${CC}\"
		else
			# this might be pcc
			${CC} -v 2>&1 | grep pcc > /dev/null || \
			    die \"${CC} -v failed\". Check \"${CC}\"
			CC_TARGET=$(${CC} -v 2>&1 \
			    | sed -n -e 's/^pcc.*for //' -e 's/,.*//p' )
		fi
	fi
	MACH_ARCH=$(echo ${CC_TARGET} | sed 's/-.*//' )

	# Set names of tools we're going to use.  try to guess them
	# for common scenarios
	if ${NATIVEBUILD} || ${KERNONLY}; then
		: ${AR:=ar}
		: ${NM:=nm}
		: ${OBJCOPY:=objcopy}
	else
		: ${AR:=${CC_TARGET}-ar}
		: ${NM:=${CC_TARGET}-nm}
		: ${OBJCOPY:=${CC_TARGET}-objcopy}
	fi

	case ${CC_TARGET} in
	*-linux*)
		RUMPKERN_UNDEF='-Ulinux -U__linux -U__linux__ -U__gnu_linux__'
		cppdefines _BIG_ENDIAN \
		    && appendvar RUMPKERN_UNDEF -U_BIG_ENDIAN
		cppdefines _LITTLE_ENDIAN \
		    && appendvar RUMPKERN_UNDEF -U_LITTLE_ENDIAN
		;;
	*-dragonflybsd)
		RUMPKERN_UNDEF='-U__DragonFly__'
		;;
	*-openbsd*)
		RUMPKERN_UNDEF='-U__OpenBSD__'
		appendvar EXTRA_CWARNFLAGS -Wno-format
		;;
	*-freebsd*)
		RUMPKERN_UNDEF='-U__FreeBSD__'
		;;
	*-sun-solaris*|*-pc-solaris*)
		RUMPKERN_UNDEF='-U__sun__ -U__sun -Usun'
		;;
	esac

	if ! cppdefines __ELF__; then
		${TITANMODE} || die ELF required as target object format
	fi

	if cppdefines __LP64__; then
		THIRTYTWO=false
	else
		THIRTYTWO=true
	fi

	# The compiler cannot do %zd/u warnings if the NetBSD kernel
	# uses the different flavor of size_t (int vs. long) than what
	# the compiler was built with.  Probing is not entirely easy
	# since we need to testbuild kernel code, not host code,
	# and we're only setting up the build now.  So we just
	# disable format warnings on all 32bit targets.
	${THIRTYTWO} && appendvar EXTRA_CWARNFLAGS -Wno-format

	# Check if cpp supports __COUNTER__.  If not, override CTASSERT
	# to avoid line number conflicts
	doesitbuild 'int a = __COUNTER__;\n' -c
	[ $? -eq 0 ] || CTASSERT="-D'CTASSERT(x)='"

	# linker supports --warn-shared-textrel
	doesitbuild 'int main(void) {return 0;}' -Wl,--warn-shared-textrel
	[ $? -ne 0 ] && SHLIB_WARNTEXTREL=no
}

# Figure out what we need for the target platform
evalplatform ()
{

	case ${CC_TARGET} in
	*-netbsd*)
		RUMP_VIRTIF=yes
		HIJACK=true
		;;
	*-dragonflybsd)
		RUMP_VIRTIF=yes
		;;
	*-linux*)
		EXTRA_RUMPCOMMON='-ldl'
		EXTRA_RUMPCLIENT='-lpthread'
		doesitbuild '#include <linux/if_tun.h>' -c && RUMP_VIRTIF=yes
		cppdefines '__ANDROID__' || HIJACK=true
		;;
	*-openbsd*)
		EXTRA_RUMPCLIENT='-lpthread'
		;;
	*-freebsd*)
		EXTRA_RUMPCLIENT='-lpthread'
		;;
	*-sun-solaris*|*-pc-solaris*)
		EXTRA_RUMPCOMMON='-lsocket -ldl -lnsl'
		# I haven't managed to get static libs to work on Solaris,
		# so just be happy with shared ones
		MKSTATICLIB=no
		SYS_SUNOS=true
		;;
	*-pc-cygwin)
		MKPIC=no
		target_supported=false
		;;
	*-apple-darwin*)
		echo '>> Mach-O object format used by OS X is not yet supported'
		target_supported=false
		;;
	*)
		target_supported=false
		;;
	esac

	if ! ${target_supported:-true}; then
		${TITANMODE} || die unsupported target: ${CC_TARGET}
	fi

	# does target support __thread.  if yes, optimize curlwp
	doesitbuild '__thread int lanka; int main(void) {return lanka;}\n'
	[ $? -eq 0 ] && RUMP_CURLWP=__thread
}

# ARM targets require a few extra checks
probearm ()
{

	# check for big endian
	if cppdefines '__ARMEL__'; then
		MACHINE="evbearm-el"
		MACH_ARCH="arm"
	else
		MACHINE="evbearm-eb"
		MACH_ARCH="armeb"
	fi

	TOOLABI="elf-eabi"

	# NetBSD/evbarm is softfloat by default, but force the NetBSD
	# build to use hardfloat if the compiler defaults to VFP.
	# This is because the softfloat env is not always functional
	# in case hardfloat is the compiler default.
	if cppdefines __VFP_FP__; then
		MKSOFTFLOAT=no
	fi
}

# aarch64 requires a few checks
probeaarch64 ()
{

	# check for big endian
	if cppdefines '__AARCH64EL__'; then
		MACHINE="evbarm64-el"
		MACH_ARCH="aarch64"
	else
		MACHINE="evbarm64-eb"
		MACH_ARCH="aarch64_be"
	fi

	TOOLABI=""

	# the NetBSD aarch64 port uses long long for int64_t
	appendvar EXTRA_CWARNFLAGS -Wno-format
}

# MIPS requires a few extra checks
probemips ()
{

	# set env vars that NetBSD expects for the different MIPS ABIs
	if cppdefines '_ABIO32'; then
		appendvar EXTRA_CFLAGS -D__mips_o32
		appendvar EXTRA_AFLAGS -D__mips_o32
	elif cppdefines '_ABIN32'; then
		appendvar EXTRA_CFLAGS -D__mips_n32
		appendvar EXTRA_AFLAGS -D__mips_n32
		${TITANMODE} || die MIPS n32 ABI not yet working, use -mabi=32
	elif cppdefines '_ABI64'; then
		appendvar EXTRA_CFLAGS -D__mips_n64
		appendvar EXTRA_AFLAGS -D__mips_n64
	else die unknown MIPS ABI
	fi

	# NetBSD/evbmips is softfloat by default
	# but we can detect if this is correct
	if cppdefines '__mips_hard_float'; then
		MKSOFTFLOAT=no
	fi

	# MIPS builds need to be position independent;
	# NetBSD hosts do this anyway but others may need forcing
	appendvar EXTRA_CFLAGS -fPIC
	appendvar EXTRA_AFLAGS -fPIC
}

evalmachine ()
{

	TOOLABI=''
	case ${MACH_ARCH} in
	"amd64"|"x86_64")
		if ${THIRTYTWO} ; then
			MACHINE="i386"
			MACH_ARCH="i486"
			TOOLABI="elf"
		else
			MACHINE="amd64"
			MACH_ARCH="x86_64"
		fi
		;;
	"i386"|"i486"|"i586"|"i686")
		MACHINE="i386"
		MACH_ARCH="i486"
		TOOLABI="elf"
		;;
	arm*)
		probearm
		;;
	aarch64*)
		probeaarch64
		;;
	"sparc"|"sparc64")
		if ${THIRTYTWO} ; then
			MACHINE="sparc"
			MACH_ARCH="sparc"
			TOOLABI="elf"
		else
			MACHINE="sparc64"
			MACH_ARCH="sparc64"
		fi
		;;
	"mipsel"|"mips64el")
		if ${THIRTYTWO} ; then
			MACHINE="evbmips-el"
			MACH_ARCH="mipsel"
		else
			MACHINE="evbmips64-el"
			MACH_ARCH="mips64el"
		fi
		probemips
		;;
	"mips"|"mipseb"|"mips64"|"mips64eb")
		if ${THIRTYTWO} ; then
			MACHINE="evbmips-eb"
			MACH_ARCH="mipseb"
		else
			MACHINE="evbmips64-eb"
			MACH_ARCH="mips64"
		fi
		probemips
		;;
	"powerpc"|"ppc64"|"powerpc64le")
		if ${THIRTYTWO} ; then
			MACHINE="evbppc"
			MACH_ARCH="powerpc"
		else
			MACHINE="evbppc64"
			MACH_ARCH="powerpc64"
		fi
		;;
	"alpha")
		MACHINE="alpha"
		MACH_ARCH="alpha"
		;;
	"riscv"|"riscv64")
		if ${THIRTYTWO} ; then
			MACHINE="riscv"
			MACH_ARCH="riscv32"
		else
			MACHINE="riscv"
			MACH_ARCH="riscv64"
		fi
		;;
	esac
	[ -z "${MACHINE}" ] && die script does not know machine \"${MACH_ARCH}\"
}

parseargs ()
{

	DBG='-O2 -g'
	TITANMODE=false
	NOISE=2
	debugginess=0
	KERNONLY=false
	NATIVENETBSD=false
	OBJDIR=./obj
	DESTDIR=./rump
	SRCDIR=./src
	JNUM=4

	while getopts 'd:DhHj:kNo:qrs:T:V:F:' opt; do
		case "$opt" in
		d)
			DESTDIR=${OPTARG}
			;;
		D)
			[ ! -z "${RUMP_DIAGNOSTIC}" ] \
			    && die Cannot specify releasy debug

			debugginess=$((debugginess+1))
			# use -O1 as the minimal supported compiler
			# optimization level.  -O0 is just too broken
			# for too many compilers and platforms
			[ ${debugginess} -gt 0 ] && DBG='-O1 -g'
			[ ${debugginess} -gt 1 ] && RUMP_DEBUG=1
			[ ${debugginess} -gt 2 ] && RUMP_LOCKDEBUG=1
			;;
		F)
			ARG=${OPTARG#*=}
			case ${OPTARG} in
				CFLAGS\=*)
					appendvar EXTRA_CFLAGS "${ARG}"
					;;
				AFLAGS\=*)
					appendvar EXTRA_AFLAGS "${ARG}"
					;;
				LDFLAGS\=*)
					appendvar EXTRA_LDFLAGS "${ARG}"
					;;
				ACFLAGS\=*)
					appendvar EXTRA_CFLAGS "${ARG}"
					appendvar EXTRA_AFLAGS "${ARG}"
					;;
				ACLFLAGS\=*)
					appendvar EXTRA_CFLAGS "${ARG}"
					appendvar EXTRA_AFLAGS "${ARG}"
					appendvar EXTRA_LDFLAGS "${ARG}"
					;;
				CPPFLAGS\=*)
					appendvar EXTRA_CPPFLAGS "${ARG}"
					;;
				DBG\=*)
					appendvar F_DBG "${ARG}"
					;;
				*)
					die Unknown flag: ${OPTARG}
					;;
			esac
			;;
		H)
			TITANMODE=true
			;;
		j)
			JNUM=${OPTARG}
			;;
		k)
			KERNONLY=true
			;;
		N)
			NATIVENETBSD=true
			;;
		o)
			OBJDIR=${OPTARG}
			;;
		q)
			# build.sh handles value going negative
			NOISE=$((NOISE-1))
			;;
		r)
			[ ${debugginess} -gt 0 ] \
			    && die Cannot specify debbuggy release
			RUMP_DIAGNOSTIC=no
			DBG=''
			;;
		s)
			SRCDIR=${OPTARG}
			;;
		T)
			BRTOOLDIR=${OPTARG}
			;;
		V)
			appendvar BUILDSH_VARGS -V ${OPTARG}
			;;
		-)
			break
			;;
		h|\?)
			helpme
			;;
		esac
	done
	shift $((${OPTIND} - 1))

	DBG="${F_DBG:-${DBG}}"

	BEQUIET="-N${NOISE}"
	[ -z "${BRTOOLDIR}" ] && BRTOOLDIR=${OBJDIR}/tooldir

	#
	# Determine what which parts we should execute.
	#
	allcmds='checkout checkoutcvs checkoutgit tools build install
	    tests fullbuild kernelheaders'
	fullbuildcmds="tools build install"

	# for compat, so that previously valid invocations don't
	# produce an error
	allcmds="${allcmds} setupdest"

	for cmd in ${allcmds}; do
		eval do${cmd}=false
	done
	if [ $# -ne 0 ]; then
		for arg in $*; do
			while true ; do
				for cmd in ${allcmds}; do
					if [ "${arg}" = "${cmd}" ]; then
						eval do${cmd}=true
						break 2
					fi
				done
				die "Invalid arg $arg"
			done
		done
	else
		[ -z "${TARBALLMODE}" ] && docheckoutgit=true
		dofullbuild=true
		dotests=true
	fi
	if ${dofullbuild} ; then
		for cmd in ${fullbuildcmds}; do
			eval do${cmd}=true
		done
	fi

	if ${docheckout} || ${docheckoutgit} ; then
		docheckout=true
		checkoutstyle=git
	fi
	if ${docheckoutcvs} ; then
		docheckout=true
		checkoutstyle=cvs
	fi

	# sanity checks
	if [ ! -z "${TARBALLMODE}" ]; then
		${docheckout} && \
		    die 'Checkout not possible in tarball mode, fetch repo'
		[ -d "${SRCDIR}" ] || die 'Sources not found from tarball'
	fi
}

abspath ()
{

	curdir=`pwd -P`
	eval cd \${${1}}
	[ $? -ne 0 ] && die Failed to resolve path "${1}"
	eval ${1}=`pwd -P`
	cd ${curdir}
}

resolvepaths ()
{

	# check if we're running from a tarball, i.e. is checkout possible
	unset TARBALLMODE
	if [ ! -f "${BRDIR}/checkout.sh" -a -f "${BRDIR}/tarup-gitdate" ]; then
		TARBALLMODE='Run from tarball'
	fi

	# resolve critical directories
	abspath BRDIR

	mkdir -p ${OBJDIR} || die cannot create ${OBJDIR}
	mkdir -p ${DESTDIR} || die cannot create ${DESTDIR}
	mkdir -p ${BRTOOLDIR} || die "cannot create ${BRTOOLDIR} (tooldir)"

	abspath DESTDIR
	abspath OBJDIR
	abspath BRTOOLDIR
	abspath SRCDIR

	RUMPMAKE="${BRTOOLDIR}/_buildrumpsh-rumpmake"

	# mini-mtree
	dstage=${OBJDIR}/dest.stage/usr
	for dir in ${dstage}/bin ${dstage}/include/rump ${dstage}/lib; do
		mkdir -p ${dir} || die "Cannot create ${dir}"
	done
	for man in cat man ; do
		for x in 1 2 3 4 5 6 7 8 9 ; do
			mkdir -p ${dstage}/share/man/${man}${x} \
			    || die create ${dstage}/share/man/${man}${x}
		done
	done
}

# create the makefiles used for building
mkmakefile ()
{

	makefile=$1
	shift
	exec 3>&1 1>${makefile}
	printf '# GENERATED FILE, MIGHT I SUGGEST NOT EDITING?\n'
	printf 'SUBDIR='
	for dir in $*; do
		case ${dir} in
		/*)
			printf ' %s' ${dir}
			;;
		*)
			printf ' %s' ${SRCDIR}/${dir}
			;;
		esac
	done

	printf '\n.include <bsd.subdir.mk>\n'
	exec 1>&3 3>&-
}

domake ()
{

	mkfile=${1}; shift
	mktarget=${1}; shift

	[ ! -x ${RUMPMAKE} ] && die "No rumpmake (${RUMPMAKE}). Forgot tools?"
	${RUMPMAKE} $* -j ${JNUM} -f ${mkfile} ${mktarget}
	[ $? -eq 0 ] || die "make $mkfile $mktarget"
}

###
###
### BEGIN SCRIPT
###
###

BRDIR=$(dirname $0)
. ${BRDIR}/subr.sh

parseargs "$@"

${docheckout} && { ${BRDIR}/checkout.sh ${checkoutstyle} ${SRCDIR} || exit 1; }

if ${dotools} || ${dobuild} || ${dokernelheaders} || ${doinstall} || ${dotests}
then
	resolvepaths

	evaltoolchain
	evalmachine

	${KERNONLY} || evalplatform

	${dotools} && maketools
	${dobuild} && makebuild
	${dokernelheaders} && makekernelheaders
	${doinstall} && makeinstall

	if ${dotests}; then
		if ${KERNONLY}; then
			echo '>> Kernel-only; skipping tests (no hypervisor)'
		else
			. ${BRDIR}/tests/testrump.sh
			alltests
		fi
	fi
fi

echo '>> buildrump.sh ran successfully'
exit 0
