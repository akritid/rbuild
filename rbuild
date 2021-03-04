#! /bin/sh

# SPDX-License-Identifier: MIT
# vim: noai:ts=4:

# Global settings
export LC_CTYPE=C
export TERM=xterm

# Configurations:User
RUSER=
RB_PROFILES=

# Configuration:Locations
RB_LOCAL_DIR_ANCHORS="configure.ac .git .hg"
RB_JOBS=1
# Remote host on which sources/binaries will be generated
RB_BHOST=
# Deploy host
RB_DHOST=
# Root directory on remote site where source and binaries will be placed.
RB_ROOT=

# Configurations:Tools
RSYNC=$(which rsync)
# Some Distro package managers name `cmake` executable differently. Use the
# correct name of full path as available on build host.
CMAKE_EXE=
CTEST_EXE=
# CMake generator to use. If unset, it uses whatever is system default. Usually,
# that's "Unix Makefiles".
CMAKE_GENERATOR=
# Colon separated list of paths CMake will look for headers/libraries.
CMAKE_PREFIX_PATH=
# Any other extra project-specific arguments to send to CMake configuration
CMAKE_EXTRAS=

# Local settings

# Configuration file to load
rb_cfg_file=
# Verbosity levels (cumulative).
#     1 - Show only the task names
#     2 - Turn on make/ninja verbosity
#     3 - Show the actual SSH command being transmitted
#     4 - Turn on full verbosity, even in SSH
rb_verbosity=0
# SSH flags. Note, verbosity settings will append -o LogLevel=QUIET later on
ssh_flags="-o BatchMode=yes -o StrictHostKeyChecking=no -o ForwardAgent=yes"
# Build configuration
rb_build_mode=debug
CMAKE_BUILD_TYPE=Debug
# Make target
rb_target=
# Directories
rdir_src=
rdir_bin=
rdir_ins=

# Actions
__rb_is_build=0
__rb_is_config=0
__rb_is_deploy=0
__rb_is_pack=0
__rb_is_reset=0
__rb_is_rsync=0
__rb_is_test=0
__rb_reset_level=0
__rb_is_dryrun=0

# Internal constants
ME=$(basename ${0})

# Too many jobs can hinder others' works. For safety, use count of local CPUs.
__rb_def_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu) || 1
__rb_def_cfg_name=.rbuild.conf

__rb_blue=$(tput setaf 4)
__rb_red=$(tput setaf 1)
__rb_norm=$(tput sgr0)

__rb_excludes=""
__rb_excludes="${__rb_excludes}*.swp\n"
__rb_excludes="${__rb_excludes}.git\n"
__rb_excludes="${__rb_excludes}.gitignore\n"
__rb_excludes="${__rb_excludes}.hg\n"
__rb_excludes="${__rb_excludes}aclocal.m4\n"
__rb_excludes="${__rb_excludes}autom4te.cache\n"
__rb_excludes="${__rb_excludes}build-aux\n"
__rb_excludes="${__rb_excludes}compile\n"
__rb_excludes="${__rb_excludes}config.guess\n"
__rb_excludes="${__rb_excludes}config.sub\n"
__rb_excludes="${__rb_excludes}configure\n"
__rb_excludes="${__rb_excludes}depcomp\n"
__rb_excludes="${__rb_excludes}install-sh\n"
__rb_excludes="${__rb_excludes}libtool.m4\n"
__rb_excludes="${__rb_excludes}ltmain.sh\n"
__rb_excludes="${__rb_excludes}ltoptions.m4\n"
__rb_excludes="${__rb_excludes}ltsugar.m4\n"
__rb_excludes="${__rb_excludes}ltversion.m4\n"
__rb_excludes="${__rb_excludes}lt~obsolete.m4\n"
__rb_excludes="${__rb_excludes}Makefile.in\n"
__rb_excludes="${__rb_excludes}missing\n"
__rb_excludes="${__rb_excludes}py-compile\n"
__rb_excludes="${__rb_excludes}test-driver\n"
__rb_excludes="${__rb_excludes}ylwrap\n"


# Show help message
rb_help()
{
	exit_code=${1}
	msg=${2}

	if [ ! -z "${msg}" ]; then
		echo "${msg}" >&2
	fi

	echo "Remote build driver for auto-tools/CMake/GNUMake"
	echo
	echo "Usage: ${ME} <-j JOBS> <-C FILE> <-e MODE> [-nv*] -[scbtp]"
	echo
	echo "-h        This help message"
	echo
	echo "-b        Build"
	echo "-B        Select custom target, for e.g. '-Bdocs'"
	echo "-c        (re)Configure"
	echo "-C [FILE] Configuration file to load"
	echo "-d        Deploy"
	echo "-e [MODE] Build mode, one of [debug, optimized]. (Default: 'debug')."
	echo "-j [JOBS] Change default number of jobs (Default: RB_JOBS=${__rb_def_jobs})."
	echo "-n        Dry run. Print command only."
	echo "-p        Generate archive of remote installation directory"
	echo "-r [TYPE] Scrub remote directories. For different TYPE values:"
	echo "            1. Run \`make clean\` or equivalent"
	echo "            2. Delete remote binary directory"
	echo "            3. Delete remote install directory"
	echo "            4. Delete remote source directory"
	echo "-s        Sync local source to remote directory"
	echo "-t        Test"
	echo "-v        More '-v', more drama!"
	echo

	exit ${exit_code}
}

# Write a success/fail log message on terminal
#
# \param $1 - Exit code
# \param $2 - Task
# \param $3 - Time taken
rb_log()
{
	exit_code=$1
	task=$2
	diff_time=$3

	if [ ${exit_code} -ne 0 ]; then
		printf "${__rb_red}[%12s]${__rb_norm} failed after %ds. Aborting..\n" \
			"${task}" \
			${diff_time}
		exit $exit_code
	fi
	if [ ${rb_verbosity} -ge 1 ]; then
		printf "${__rb_blue}[%12s]${__rb_norm} finished in %ds.\n" \
			"${task}" \
			${diff_time}
	fi
}

# Run $* remotely.
#
# \param $1 A human readable name of the task executed remotely
# \param $2 Remote host
# \param $3 Command to execute on remote server
#
# \example
# Call this function as:
#     ssh_call "ls" "example.com" "ls --color=always -lh /usr/include"
ssh_call()
{
	args=
	ret=
	cmdline=

	task=${1}
	shift

	# Set some SSH flags
	args="${__ssh_flags}"
	# If `rbuild` is invoked from shell, request pseudo terminal for SSH
	if [ -t 1 ] || [ -t 2 ]; then
		args="${args} -t"
	fi
	# If verbosity levels are too high, start true crime drama with SSH
	if [ ${rb_verbosity} -ge 4 ]; then
		args="${args} -v"
	fi
	# If there's a remote user specified, set that too. Otherwise assume
	# whatever the current local user's ~/.ssh/config says about RB_HOST.
	if [ ! -z "${RUSER}" ]; then
		args="${args} -l${RUSER}"
	fi
	# Set remote host
	args="${args} ${1}"
	# Use remote profile settings. If scripts are specified in RB_POFILES, those
	# scripts are sourced before running the actual commands. For example, some
	# compilers provide `enable` script to temporarily switch over to that
	# compiler in PATH. Setting RB_PROFILES can enable that for this SSH session.
	if [ ! -z "${RB_PROFILES}" ]; then
		for p in $(echo "${RB_PROFILES}" | sed "s/:/ /g"); do
			cmdline=". ${p}; "
		done
	fi
	# Finally inject the remaining command.
	cmdline="${cmdline}${2}"

	if [ ${rb_verbosity} -ge 3 ] || [ ${__rb_is_dryrun} -eq 1 ]; then
		echo "ssh ${args} \"${cmdline}\""
	fi

	# Timing the command here will include the time spent on network as well.
	# Shouldn't be too relevant over multiple runs.
	diff_time=0
	ret=0
	if [ ${__rb_is_dryrun} -eq 0 ]; then
		t_start=$(date +%s)
		ssh ${args} ${cmdline}
		ret=$?
		t_end=$(date +%s)
		diff_time=$(expr $t_end - $t_start)
	fi

	rb_log ${ret} ${task} ${diff_time}
}

# Locate one or more files either in current directory or its parents until that
# file is found.
upsearch()
{
	ldir=
	pdir=

	for file in "$@"; do
		ldir=$(pwd)
		is_found=0
		while [ -n "${ldir}" ]; do
			if [ -e "${ldir}/${file}" ]; then
				echo "${ldir}"
				is_found=1
				break
			fi
			pdir=$(dirname "${ldir}")

			if [ "${ldir}" = "${pdir}" ]; then
				break
			fi
			ldir="${pdir}"
		done
		if [ ${is_found} -eq 1 ]; then
			break
		fi
	done

	echo ""
}

# Prepare exclude list
x_file=
rb_prep_exclist()
{
	x_file=$(mktemp)
	u_file="${x_file}u"
	printf "${__rb_excludes}" > "${x_file}"
	# If the current directory contains a list, append that too
	if [ -f .rbuild.exclude ]; then
		cat .rbuild.exclude >> "${x_file}"
	fi
	uniq "${x_file}" > "${u_file}"
	mv "${u_file}" "${x_file}"
}

# Synchronise local sources to remote site.
#
rb_sync()
{
	r_args= # For rSync
	s_args= # For SSH

	rb_prep_exclist

	r_args="-chlrz"
	if [ $rb_verbosity -ge 2 ]; then
		r_args="${r_args} -v --progress"
	else
		r_args="${r_args} -q"
	fi
	r_args="${r_args} --inplace"
	r_args="${r_args} --del"
	r_args="${r_args} --cvs-exclude"
	r_args="${r_args} --exclude-from=${x_file}"

	s_args="ssh ${__ssh_flags}"

	r_path=
	if [ ! -z "${RUSER}" ]; then
		r_path="${RUSER}@${RB_BHOST}"
	else
		r_path="${RB_BHOST}"
	fi
	r_path="${r_path}:${rdir_src}/"

	if [ $rb_verbosity -ge 3 ] || [ ${__rb_is_dryrun} -ne 0 ]; then
		printf "rsync %s -e %s --rsync-path=\"%s && %s\" ./ %s\n" \
			"${r_args}" \
			"${s_args}" \
			"${rdir_src}" \
			"${RSYNC}" \
			"${r_path}"
	fi

	diff_time=0
	ret=0
	if [ ${__rb_is_dryrun} -eq 0 ]; then
		t_start=$(date +%s)
		RSYNC_OLD_ARGS=1 rsync \
			${r_args} \
			-e "${s_args}" \
			--rsync-path="mkdir -p ${rdir_src} && ${RSYNC}" \
			./ "${r_path}"
		ret=$?
		t_end=$(date +%s)
		diff_time=$(expr $t_end - $t_start)
	fi

	rm -f "${x_file}"

	rb_log ${ret} "rsync" ${diff_time}
}

# Load configuration file and initialise build environment
rb_init()
{
	ldir_src=

	if [ -z "${rb_cfg_file}" ]; then
		echo "Configuration does not exist"
		exit 1
	fi

	ldir_src=$(upsearch ${RB_LOCAL_DIR_ANCHORS})
	if [ -z "${ldir_src}" ]; then
		echo "Cannot locate local source repository"
		exit 1
	fi

	if [ -f "${ldir_src}/CMakeLists.txt" ]; then
		rb_method="cmake"
	elif [ -f "${ldir_src}/configure.ac" ]; then
		rb_method="auto"
	elif [ -f "${ldir_src}/Makefile" ] || [ -f "${ldir_src}/GNUMakefile" ]; then
		rb_method="make"
	else
		echo "Could not recognise build method."
		echo "No Makefile/CMakeLists.txt/configure.ac found in ${ldir_src}"
		exit 1
	fi

	# Load configuration
	. ${rb_cfg_file}

	if [ -z "${RB_BHOST}" ]; then
		echo "No build-host specified."
		exit 1
	fi

	_name=$(basename "${ldir_src}")
	rdir_src="${RB_ROOT}/${_name}"
	rdir_bin="${RB_ROOT}/${_name}.${rb_build_mode}"
	rdir_ins="${RB_ROOT}/${rb_build_mode}"

	if [ "${rb_method}" = "auto" ]; then
		__saved_jobs=${RB_JOBS}
		# In case of auto-tools reload the configuration once more so
		# `AUTO_EXTRA_CONFIGURE_ARGS` can be fine tuned with our newly
		# discovered variables. Clear out all the variables to start fresh as
		# sometimes they may just be adding on themselves.
		AUTO_EXTRA_CONFIGURE_ARGS=
		CMAKE_EXE=
		CMAKE_EXTRAS=
		CMAKE_GENERATOR=
		CMAKE_PREFIX_PATH=
		CTEST_EXE=
		PKG_CONFIG_PATH=
		RB_BHOST=
		RB_DHOST=
		RB_ROOT=
		RSYNC=
		RUSER=
		AR=
		CC=
		CCAS=
		CXX=
		LINKER=
		NM=
		RANLIB=
		STRIP=

		. "${rb_cfg_file}"

		RB_JOBS=${__saved_jobs}
	fi

	if [ -z "${RB_BHOST}" ]; then
		echo "The configuration file is invalid."
		echo "Must specify a remote build host in 'RB_BHOST=' variable"
		exit 1
	fi

	if [ -z "${RB_ROOT}" ]; then
		# TODO - Better to SSH and figure out the home path something like:
		#     ssh .. "echo ${HOME}"
		if [ ! -z "${RUSER}" ]; then
			RB_ROOT="/home/${RUSER}/rbuild"
		else
			RB_ROOT="/home/${USER}/rbuild"
		fi
	fi
}

# Reset remote site
rb_reset()
{
	rm_cmd="rm -rf"
	if [ ${rb_verbosity} -ge 2 ]; then
		rm_cmd="${rm_cmd} -v"
	fi

	if [ ${__rb_reset_level} -eq 1 ]; then
		if [ "${rb_method}" = "cmake" ]; then
			# With CMake it's best to trigger `clean` target by letting CMake
			# decide how to call it using the right generator.
			if [ -z "${CMAKE_EXE}" ]; then
				args="cmake"
			else
				args="${CMAKE_EXE}"
			fi
			args="${args} --build ${rdir_bin}"
			args="${args} -j ${RB_JOBS}"
			if [ ! -z "${rb_target}" ]; then
				args="${args} -t ${rb_target}"
			else
				args="${args} -t clean"
			fi

			if [ ${rb_verbosity} -ge 2 ]; then
				args="${args} -v"
			fi

			ssh_call "Reset-1" "${RB_BHOST}" "${args}"
		elif [ "${rb_method}" = "auto" ] || [ "${rb_method}" = "make" ]; then
			args="make"
			args="${args} -C${rdir_bin}"
			args="${args} -j${RB_JOBS}"

			# We assume both handmade Makefile and autotools generated Makefile
			# use `V=1` to enable verbosity.
			if [ ${rb_verbosity} -ge 2 ]; then
				args="${args} V=1"
			fi

			if [ ! -z "${rb_target}" ]; then
				args="${args} ${rb_target}"
			else
				args="${args} clean"
			fi

			ssh_call "Reset-1" "${RB_BHOST}" "${args}"
		fi
		return 0
	fi

	args="cd ${RB_ROOT}; ${rm_cmd}"
	if [ ${__rb_reset_level} -ge 4 ]; then
		args="${args} ${rdir_src}"
	fi
	if [ ${__rb_reset_level} -ge 3 ]; then
		args="${args} ${rdir_ins}"
	fi
	if [ ${__rb_reset_level} -ge 2 ]; then
		args="${args} ${rdir_bin}"
		if [ ${rb_method} = "auto" ]; then
			# Only in auto-tools mode. Delete these excess files so we can run
			# autoreconf --install again.
			args="${args} ${rdir_src}/configure"
			args="${args} ${rdir_src}/build-aux"
			args="${args} ${rdir_src}/autom4te.cache"
			args="${args} ${rdir_src}/aclocal.m4"
		fi
	fi
	ssh_call "Reset-${__rb_reset_level}" "${RB_BHOST}" "${args}"
}

auto_config()
{
	envs=""
	if [ ! -z "${SCAN_BUILD}" ]; then
		envs="${envs} CC=${SCAN_BUILD}"
		envs="${envs} CXX=${SCAN_BUILD}"
	else
		if [ ! -z "${CC}" ]; then
			envs="${envs} CC=${CC}"
		fi
		if [ ! -z "${CXX}" ]; then
			envs="${envs} CXX=${CXX}"
		fi
	fi
	if [ ! -z "${AR}" ]; then
		envs="${envs} AR=${AR}"
	fi
	if [ ! -z "${RANLIB}" ]; then
		envs="${envs} RANLIB=${RANLIB}"
	fi
	if [ ! -z "${NM}" ]; then
		envs="${envs} NM=${NM}"
	fi
	if [ ! -z "${LINKER}" ]; then
		envs="${envs} LINKER=${LINKER}"
	fi
	if [ ! -z "${CCAS}" ]; then
		envs="${envs} CCAS=${CCAS}"
	fi
	if [ ! -z "${CFLAGS}" ]; then
		envs="${envs} CFLAGS=\"${CFLAGS}\""
	fi
	if [ ! -z "${CXXFLAGS}" ]; then
		envs="${envs} CXXFLAGS=\"${CXXFLAGS}\""
	fi
	if [ ! -z "${GIT_REVISION}" ]; then
		envs="${envs} GIT_REVISION=${GIT_REVISION}"
	fi
	envs="${envs} ACLOCAL_PATH=${rdir_ins}/share/aclocal"
	envs="${envs} PKG_CONFIG_PATH=${rdir_ins}/lib/pkgconfig:${rdir_ins}/lib64/pkgconfig"
	if [ ! -z "${PKG_CONFIG_PATH}" ]; then
		envs="${envs}:${PKG_CONFIG_PATH}"
	fi

	s_args="${__ssh_flags}"
	if [ ! -z "${RUSER}" ]; then
		s_args="${s_args} -l${RUSER}"
	fi
	s_args="${s_args} ${RB_BHOST}"

	if ! ssh ${s_args} "test -f ${rdir_src}/configure"; then
		# Call auto-reconf
		cmd=
		cmd="${envs} autoreconf --install"
		ssh_call "Setup" \
			"${RB_BHOST}" \
			"mkdir -p ${rdir_src} && cd ${rdir_src} && ${cmd}"
	fi
	# Then call configure script
	cmd=
	cmd="${envs} ${rdir_src}/configure"
	cmd="${cmd} --prefix=${rdir_ins}"
	if [ -z "${AUTO_EXTRA_CONFIGURE_ARGS}" ]; then
		cmd="${cmd} ${AUTO_EXTRA_CONFIGURE_ARGS}"
	fi
	ssh_call "Configure" \
		"${RB_BHOST}" \
		"mkdir -p ${rdir_bin} && cd ${rdir_bin} && ${cmd}"
}

cmake_config()
{
	args=

	args="PKG_CONFIG_PATH=${rdir_ins}/lib/pkgconfig:${rdir_ins}/lib64/pkgconfig"
	if [ ! -z "${PKG_CONFIG_PATH}" ]; then
		args="${args}:${PKG_CONFIG_PATH}"
	fi
	if [ ! -z "${GIT_REVISION}" ]; then
		args="${args} GIT_REVISION=${GIT_REVISION}"
	fi

	if [ -z "${CMAKE_EXE}" ]; then
		args="${args} cmake"
	else
		args="${args} ${CMAKE_EXE}"
	fi
	args="${args} -S${rdir_src}"
	args="${args} -B${rdir_bin}"
	args="${args} -Werror=dev"
	args="${args} --warn-uninitialized"

	if [ ! -z "${CMAKE_GENERATOR}" ]; then
		args="${args} -G\"${CMAKE_GENERATOR}\""
	fi
	if [ ! -z "${CC}" ]; then
		args="${args} -DCMAKE_C_COMPILER=${CC}"
	fi
	if [ ! -z "${CXX}" ]; then
		args="${args} -DCMAKE_CXX_COMPILER=${CXX}"
	fi
	if [ ! -z "${AR}" ]; then
		args="${args} -DCMAKE_AR=${AR}"
	fi
	if [ ! -z "${RANLIB}" ]; then
		args="${args} -DCMAKE_RANLIB=${RANLIB}"
	fi
	if [ ! -z "${NM}" ]; then
		args="${args} -DCMAKE_NM=${NM}"
	fi
	if [ ! -z "${LINKER}" ]; then
		args="${args} -DCMAKE_LINKER=${LINKER}"
	fi
	if [ ! -z "${STRIP}" ]; then
		args="${args} -DCMAKE_STRIP=${STRIP}"
	fi
	if [ ! -z "${CMAKE_EXTRAS}" ]; then
		args="${args} ${CMAKE_EXTRAS}"
	fi

	# TODO - This disables "Installing: blah/blah" or "Up-to-Date: blah/blah"
	# message. But once passed in configuration it can't be modified later
	# through rbuild CLI. For large projects, this will print way too many
	# lines obstructing the real stuff. Should this be configured here under
	# `-v` settings?
	if [ ${rb_verbosity} -ge 2 ]; then
		args="${args} -DCMAKE_INSTALL_MESSAGE=ALWAYS"
	else
		args="${args} -DCMAKE_INSTALL_MESSAGE=NEVER"
	fi

	args="${args} -DCMAKE_INSTALL_PREFIX=${rdir_ins}"
	args="${args} -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}"
	# Since we're converting a colon separated list to semicolon separated list,
	# we need to ensure the string is quoted. Otherwise the shell will treat
	# the second item like another command.
	if [ ! -z "${CMAKE_PREFIX_PATH}" ]; then
		args="${args} -DCMAKE_PREFIX_PATH=\"${rdir_ins};$(echo "${CMAKE_PREFIX_PATH}" | sed "s/:/;/g")\""
	else
		args="${args} -DCMAKE_PREFIX_PATH=${rdir_ins}"
	fi

	ssh_call "Configure" "${RB_BHOST}" "${args}"
}

make_config()
{
	:
}

auto_build()
{
	args=

	args="-C${rdir_bin}"
	args="${args} -j${RB_JOBS}"
	if [ ${rb_verbosity} -ge 4 ]; then
		args="${args} V=1"
	fi
	if [ ! -z "${rb_target}" ]; then
		args="${args} ${rb_target}"
	else
		args="${args} install"
	fi

	ssh_call "Build" "${RB_BHOST}" "make ${args}"
}

cmake_build()
{
	args=

	if [ -z "${CMAKE_EXE}" ]; then
		args="cmake"
	else
		args="${CMAKE_EXE}"
	fi
	args="${args} --build ${rdir_bin}"
	if [ ! -z "${rb_target}" ]; then
		args="${args} -t ${rb_target}"
	else
		# Assume `install` target always exists
		args="${args} -t install"
	fi
	# On Ninja, if `-j` is left unspecified, it will run as many parallel jobs
	# as there are CPUs on the build machine. Not ideal.
	args="${args} -j ${RB_JOBS}"
	if [ ${rb_verbosity} -ge 4 ]; then
		args="${args} -v"
	fi

	ssh_call "Build" "${RB_BHOST}" "${args}"
}

make_build()
{
	args=
	env=""

	if [ ! -z "${CC}" ]; then
		env="${env} CC=${CC}"
	fi
	if [ ! -z "${CXX}" ]; then
		env="${env} CXX=${CXX}"
	fi
	if [ ! -z "${AR}" ]; then
		env="${env} AR=${AR}"
	fi
	if [ ! -z "${RANLIB}" ]; then
		env="${env} RANLIB=${RANLIB}"
	fi
	if [ ! -z "${NM}" ]; then
		env="${env} NM=${NM}"
	fi
	if [ ! -z "${LINKER}" ]; then
		env="${env} LINKER=${LINKER}"
	fi
	if [ ! -z "${CCAS}" ]; then
		env="${env} CCAS=${CCAS}"
	fi
	if [ ! -z "${CFLAGS}" ]; then
		env="${env} CFLAGS=\"${CFLAGS}\""
	fi

	args="cd ${rdir_src};"
	args="${args} ${env} gmake"
	args="${args} -j${RB_JOBS}"
	args="${args} DIR_BIN=${rdir_bin}"
	args="${args} PREFIX=${rdir_ins}"
	if [ ${rb_verbosity} -ge 2 ]; then
		args="${args} V=1"
	fi
	if [ ! -z "${GMAKE_EXTRAS}" ]; then
		args="${args} ${GMAKE_EXTRAS}"
	fi
	if [ ! -z "${rb_target}" ]; then
		args="${args} -t ${rb_target}"
	fi

	ssh_call "Build" "${RB_BHOST}" "${args}"
}

auto_test()
{
	args=

	args="-C${rdir_bin}"
	# XXX - Cannot run tests in parallel because autotools generates Makefile is
	# very poorly isolated. This is a developer error and not autotools' fault.
	# Either we correct it or use a better build system.
	args="${args} -j1"
	if [ ${rb_verbosity} -ge 4 ]; then
		args="${args} V=1"
	fi
	if [ ! -z "${rb_target}" ]; then
		args="${args} ${rb_target}"
	else
		args="${args} check"
	fi

	ssh_call "Test" "${RB_BHOST}" "make ${args}"
}

cmake_test()
{
	args=

	if [ -z "${CTEST_EXE}" ]; then
		args="ctest"
	else
		args="${CTEST_EXE}"
	fi

	args="${args} --output-on-failure"
	args="${args} --stop-on-failure"
	args="${args} -j ${RB_JOBS}"
	args="${args} -O ${rdir_bin}/tests.log"

	if [ ${rb_verbosity} -ge 4 ]; then
		args="${args} -VV --debug"
	elif [ ${rb_verbosity} -ge 3 ]; then
		args="${args} -VV"
	elif [ ${rb_verbosity} -ge 2 ]; then
		args="${args} -V"
	fi

	ssh_call "Test" "${RB_BHOST}" "cd ${rdir_bin}; ${args}"
}

make_test()
{
	:
}

rb_package()
{
	args=

	if [ $is_verbose -ge 4 ]; then
		args="${args} -v"
	fi
	args="${args} -caf"
	args="${args} ${RB_ROOT}/${rb_build_mode}.tar.xz"
	args="${args} *"

	ssh_call "Package" "${RB_BHOST}" "cd ${rdir_ins} && tar ${args}"
}

rb_deploy()
{
	cmd=
	r_args= # For rSync
	s_args= # For SSH

	r_args="-avz"
	if [ $rb_verbosity -ge 2 ]; then
		r_args="${r_args} -v --progress"
	else
		r_args="${r_args} -q"
	fi
	r_args="${r_args} --del"

	s_args="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ForwardAgent=yes"

	cmd="rsync ${r_args} -e \"${s_args}\""
	cmd="${cmd} --rsync-path=\"mkdir -p ${rdir_ins} && ${RSYNC}\""
	cmd="${cmd} ${rdir_ins}"
	cmd="${cmd} ${RUSER}@${RB_DHOST}:${rdir_ins}/"

	ssh_call "Deploy" "${RB_BHOST}" "${cmd}"
}

rb_set_cfg_file()
{
	ldir=

	rb_cfg_file=
	ldir=$(upsearch "${1}")
	if [ ! -z "${ldir}" ]; then
		rb_cfg_file="${ldir}/${1}"
	elif [ -e "${HOME}/${1}" ]; then
		rb_cfg_file="${HOME}/${1}"
	fi
}

rb_set_build_type()
{
	if [ ${1} = "debug" ]; then
		rb_build_mode=debug
		CMAKE_BUILD_TYPE=Debug
	elif [ ${1} = "optimized" ] || [ ${1} = "optimised" ]; then
		rb_build_mode=optimized
		CMAKE_BUILD_TYPE=RelWithDebInfo
	else
		echo "Build type must be one of ['debug', 'optimized']. Got '-e${1}'"
		exit 1
	fi
}

is_integer()
{
	case "${1#[+-]}" in
		(*[![:digit:]]*)  return 1 ;;
		(*)               return 0 ;;
	esac
}

rb_set_build_jobs()
{
	jobs="${1}"
	is_integer "${jobs}"
	if [ $? -ne 0 ]; then
		echo "Jobs must be an integer. Got '-j${jobs}'"
		exit 1
	fi
	if [ "${jobs}" -le 0 ] || [ "${jobs}" -gt 255 ]; then
		echo "Invalid job count. Must be between 0 and 255"
		exit 1
	fi
	if [ ${jobs} -gt 0 ]; then
		RB_JOBS=${jobs}
	fi
}

rb_set_reset_level()
{
	level=${1}

	is_integer "${level}"
	if [ $? -ne 0 ]; then
		echo "Reset level must be an integer between 1-4. Got '-r${level}'"
		exit 1
	fi
	if [ "${level}" -lt 1 ] || [ "${level}" -gt 4 ]; then
		echo "Reset level must be between 1-4. Got '-r${level}'"
		exit 1
	fi
	__rb_reset_level=${level}
}

rb_cfg_set_git()
{
	is_git=$(upsearch ".git")
	if [ ! -z "${is_git}" ]; then
		GIT_REVISION=$(git rev-parse HEAD)
		export GIT_REVISION
	fi
}

RB_JOBS=${__rb_def_jobs}
rb_set_cfg_file "${__rb_def_cfg_name}"
rb_cfg_set_git

while getopts "bB:cC:dE:e:hj:npr:stv" opt; do
	case "${opt}" in
		b) __rb_is_build=1; __rb_is_rsync=1         ;;
		B) rb_target=${OPTARG}                      ;;
		c) __rb_is_config=1; __rb_is_rsync=1        ;;
		C) rb_set_cfg_file "${OPTARG}"              ;;
		d) __rb_is_deploy=1                         ;;
		e) rb_set_build_type "${OPTARG}"            ;;
		h) rb_help 0                                ;;
		j) rb_set_build_jobs "${OPTARG}"            ;;
		n) __rb_is_dryrun=1                         ;;
		p) __rb_is_pack=1                           ;;
		r) rb_set_reset_level "${OPTARG}"           ;;
		s) __rb_is_rsync=1                          ;;
		t) __rb_is_test=1; __rb_is_rsync=1          ;;
		v) rb_verbosity=$(expr ${rb_verbosity} + 1) ;;
		*) rb_help 1 "${OPTARG}"                    ;;
	esac
done
if [ $OPTIND -eq 1 ]; then
	# Default behaviour if no options are given.
	__rb_is_rsync=1
	__rb_is_build=1
	exit 0
fi

# If verbosity is too high, start true crime drama!
if [ ${rb_verbosity} -ge 4 ]; then
	__ssh_flags="${__ssh_flags} -o LogLevel=VERBOSE"
else
	__ssh_flags="${__ssh_flags} -o LogLevel=QUIET"
fi

rb_init

if [ $__rb_reset_level -ne 0 ]; then
	rb_reset
fi
if [ $__rb_is_rsync -eq 1 ]; then
	rb_sync
fi
if [ $__rb_is_config -eq 1 ]; then
	${rb_method}_config
fi
if [ $__rb_is_build -eq 1 ]; then
	${rb_method}_build
fi
if [ $__rb_is_test -eq 1 ]; then
	${rb_method}_test
fi
if [ $__rb_is_pack -eq 1 ]; then
	rb_package
fi
if [ $__rb_is_deploy -eq 1 ]; then
	rb_deploy
fi
