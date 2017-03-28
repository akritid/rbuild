#!/bin/bash

LC_CTYPE=C
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ForwardAgent=yes"
LOCAL_DIR_ANCHORS=".hg .git configure.ac"
BUILD_ENV=debug
INSTALL_DIR='$HOME/.local'
BUILD_JOBS=8
RBUILD_DIR=rbuild

upsearch () {
    slashes=${PWD//[^\/]/}
    directory="$PWD"
    for (( n=${#slashes}; n>0; --n ))
    do
        for i in $*; do
            test -e "$directory/$i" && echo "$directory/$i" && return 
        done
        directory="$directory/.."
    done
}

function load_conf {
    if [ -z $1 ]; then
        conf=$(upsearch .rbuild.conf)
    else
        conf=$1
    fi

    if [ -z "$conf" ]; then
        if [ -e $HOME/.rbuild.conf ]; then
            . $HOME/.rbuild.conf
        else
            echo >&2 "Could not find required file .rbuild.conf or ~/.rbuild.conf"
            echo >&2 "Please create one and rerun to get additional instructions"
            exit 1
        fi
    else
        . "$conf"
    fi

    LOCAL_DIR=${LOCAL_DIR:-$(dirname "$(upsearch $LOCAL_DIR_ANCHORS)")}
    # cd into dir to normalize it
    cd "$LOCAL_DIR"
    LOCAL_DIR=$PWD
    BASENAME=${BASENAME:-$(basename "$LOCAL_DIR")}
    STAGING_DIR="${STAGING_DIR:-$RBUILD_DIR/$BASENAME}"
    BUILD_DIR=${BUILD_DIR:-$RBUILD_DIR/$BASENAME.$BUILD_ENV}

    if [ -z "$BUILD_HOST" ]; then
        echo >&2 "BUILD_HOST not set"
        echo >&2 "Please set it in .rbuild.conf, for example: BUILD_HOST=somehost"
        echo >&2 "The host name is resolved on your local machine"
        exit 1
    fi
}


function stage {
    echo Staging source from $LOCAL_DIR to $BUILD_HOST:$STAGING_DIR

    if [ -e "$PWD/.rbuild.exclude" ]; then
        exclude="$PWD/.rbuild.exclude"
        echo >&2 "Using rsync exclude file $exclude"
    else
        if [ -e $HOME/.rbuild.exclude ]; then
            exclude="$HOME/.rbuild.exclude"
            echo >&2 "Using rsync exclude file $exclude"
        else
            echo >&2 "Using built-in rsync exclude file list (displayed with $0 -x)"
            exclude="<($0 -x)"
        fi
    fi

    rsync -r -l -c --executability --del --inplace  -z -e "$SSH" --rsync-path="mkdir -p \"$STAGING_DIR\" && rsync" --cvs-exclude --exclude .hg --exclude .git --exclude-from <($0 -x) "$LOCAL_DIR/" "$BUILD_HOST:\"$STAGING_DIR\""
}

function autoreconf {
    echo Remote autoreconf in $BUILD_HOST:$STAGING_DIR
    $SSH $BUILD_HOST "cd \"$STAGING_DIR\" && autoreconf --install"
}

function configure {
    echo Remote configure in $BUILD_HOST:$BUILD_DIR
    $SSH $BUILD_HOST "mkdir -p \"$BUILD_DIR\" && cd \"$BUILD_DIR\" && eval $CONFIGURE_VARS \"../$BASENAME/configure\" $CONFIGURE_ARGS"
}

function build {
    echo Remote build $1 in $BUILD_HOST:$BUILD_DIR
    $SSH $BUILD_HOST "make -C $BUILD_DIR -j$BUILD_JOBS $1"
}

function check {
    echo Running tests in $BUILD_HOST:$BUILD_DIR
    $SSH $BUILD_HOST "make -C $BUILD_DIR check || cat $BUILD_DIR/test-suite.log"
}

function clean {
    echo Remote clean in $BUILD_HOST:$BUILD_DIR
    $SSH $BUILD_HOST "make -C $BUILD_DIR clean"
}

function rm_build_dir {
    echo Removing $BUILD_HOST:$BUILD_DIR
    $SSH $BUILD_HOST "rm -rf \"$BUILD_DIR\""
}

function deploy {
    if [ -z "$DEPLOY_HOST" ]; then
        echo >&2 "DEPLOY_HOST not set"
        echo >&2 "Please set it using an IP address in .rbuild.conf, for example: DEPLOY_HOST=10.14.0.11"
        exit 1
    fi
    echo Deploy $INSTALL_DIR/$BASENAME from $BUILD_HOST to $DEPLOY_HOST
    $SSH -A $BUILD_HOST rsync --del -avz -e "\"$SSH\"" --rsync-path="\"mkdir -p $INSTALL_DIR && rsync\"" "$INSTALL_DIR/$BASENAME/" "$DEPLOY_HOST:$INSTALL_DIR/$BASENAME"
}

function deploy_source {
    if [ -z "$DEPLOY_HOST" ]; then
        echo >&2 "DEPLOY_HOST not set"
        echo >&2 "Please set it using an IP address in .rbuild.conf, for example: DEPLOY_HOST=10.14.0.11"
        exit 1
    fi
    echo Code push $STAGING_DIR from $BUILD_HOST to $DEPLOY_HOST
    $SSH -A $BUILD_HOST rsync --del -avz -e "\"$SSH\"" --rsync-path=\""mkdir -p $RBUILD_DIR && rsync\"" "$STAGING_DIR/" "$DEPLOY_HOST:$STAGING_DIR"
}

function retract_source {
    if [ -z "$DEPLOY_HOST" ]; then
        echo >&2 "DEPLOY_HOST not set"
        echo >&2 "Please set it using an IP address in .rbuild.conf, for example: DEPLOY_HOST=10.14.0.11"
        exit 1
    fi
    echo Removing source code from $DEPLOY_HOST:$STAGING_DIR
    $SSH -A $BUILD_HOST $SSH $DEPLOY_HOST rm -rf $STAGING_DIR
}

function dump_exclude_list {
    cat <<_EOF_
*.swp
.git
.hg
Makefile.in
aclocal.m4
autom4te.cache
compile
config.guess
config.h.in
config.sub
configure
depcomp
install-sh
libtool.m4
ltmain.sh
ltoptions.m4
ltsugar.m4
ltversion.m4
lt~obsolete.m4
missing
py-compile
test-driver
ylwrap
build-aux
_EOF_
}

noargs=1
while getopts "he:scAaB:brtdD:SRoj:i:x" arg; do
    unset noargs
    case $arg in
        h)
            echo "Usage:" 
            echo -e "-s\t\tStage source code from the current directory to BUILD_HOST"
            echo -e "-c\t\tRun 'make clean' on BUILD_HOST"
            echo -e "-A\t\tRun 'autoreconf --install' on BUILD_HOST"
            echo -e "-a\t\tRun 'configure' on BUILD_HOST"
            echo -e "-B TARGET\tRun 'make TARGET' on BUILD_HOST"
            echo -e "-b\t\tRun 'make install' on BUILD_HOST"
            echo -e "-r\t\tRemove build directory (when 'make clean' is not enough)"
            echo -e "-d\t\tDeploy binaries from BUILD_HOST to DEPLOY_HOST"
            echo -e "-D HOST\t\tDeploy binaries from BUILD_HOST to HOST"
            echo -e "-S\t\tDeploy source code from BUILD_HOST to DEPLOY_HOST (e.g. for GDB)"
            echo -e "-R\t\tRemove source code from DEPLOY_HOST the deploy host"
            echo
            echo -e "-e ENV\t\tSpecify a build environment. Made available as BUILD_ENV for the config file (default=debug)"
            echo -e "-o\t\tShortcut to set BUILD_ENV=optimized"
            echo -e "-j\t\tDefine number of build jobs to run simultaneously (default: 8)"
            echo -e "-C FILE\t\tSpecify the rbuild configuration file (default = $HOME/.rbuild.conf)"
            echo -e "-x\t\tDump built-in exclude list"
            exit 1
            ;;
        x)
            dump_exclude_list
            ;;
        e)
            BUILD_ENV=${OPTARG}
            ;;
        s)
            do_stage=1
            ;;
        c)
            do_clean=1
            ;;
        A)
            do_autoreconf=1
            ;;
        a)
            do_configure=1
            ;;
        B)
            build_target=${OPTARG}
            ;;
        r)
            do_rm_build_dir=1
            ;;
        b)
            do_build=1
            ;;
        d)
            do_deploy=1
            ;;
        D)
            deploy_host=${OPTARG}
            do_deploy=1
            ;;
        S)
            do_deploy_source=1
            ;;
        R)
            do_retract_source=1
            ;;
        o)
            BUILD_ENV=optimized
            ;;
        j)
            BUILD_JOBS="${OPTARG}"
            ;;
        i)
            config_file=${OPTARG}
            ;;
    esac
done
shift $(expr $OPTIND - 1 )

if [ $noargs ]; then
    do_stage=1
    do_build=1
fi

export BUILD_ENV

load_conf $config_file


if [ -n "$deploy_host" ]; then
    DEPLOY_HOST=$deploy_host
fi

CONFIGURE_VARS="${CONFIGURE_VARS:-PKG_CONFIG_PATH=\'$PKG_CONFIG_PATH\' CC=\'$CC\' CFLAGS=\'$CFLAGS\' CCAS=gcc CCASFLAGS=}"
CONFIGURE_VARS+=" $EXTRA_CONFIGURE_VARS"

CONFIGURE_ARGS="${CONFIGURE_ARGS:---prefix $INSTALL_DIR/$BASENAME}"
CONFIGURE_ARGS+=" $EXTRA_CONFIGURE_ARGS"

if [ $do_stage ]; then
    stage || exit 1
fi

if [ $do_clean ]; then
    clean || exit 1
fi

if [ $do_rm_build_dir ]; then
    rm_build_dir || exit 1
fi

if [ $do_autoreconf ]; then
    autoreconf || exit 1
fi

if [ $do_configure ]; then
    configure || exit 1
fi

if [ $do_build ]; then
    build "install" || exit 1
fi

if [ $build_target ]; then
    build $build_target || exit 1
fi

if [ $do_deploy ]; then
    deploy || exit 1
fi

if [ $do_deploy_source ]; then
    deploy_source || exit 1
fi

if [ $do_retract_source ]; then
    retract_source || exit 1
fi

# vim: sw=4 sts=4 expandtab
