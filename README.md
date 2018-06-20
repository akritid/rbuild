# rbuild: Edit locally, build remotely

rbuild is a script to support the workflow of editing C source code
on a local machine (e.g. a macOS laptop with MacVim), and syncing the
source code to a remote build machine with full development environment
(e.g. a Linux server). It can also be used to sync the generated binaries to a
third machine lacking a development environment.

In the normal rbuild workflow, the developer edits locally, and
runs `rbuild -s` to stage the source code to the build machine and
`rbuild -b` to perform a remote build. These can be combined into
`rbuild -sb`, which are also the default options when running rbuild
without any arguments. rbuild requires a configuration file found
in `$HOME/.rbuild.conf` or provided using the `-C` option. This file
needs to include at the very least a `BUILD_HOST` variable with the name
of the build machine.

`rbuild -s` stages the source code from `LOCAL_DIR` to
`BUILD_HOST:STAGING_DIR` using `rsync`. Unless overriden in the
config file, `STAGING_DIR` defaults to `RBUILD_DIR\BASENAME`.
`RBUILD_DIR` and `BASENAME` can be overriden too, but by default
`RBUILD_DIR` is `rbuild` and `BASENAME` is the basename of `LOCAL_DIR`.
`LOCAL_DIR` can be overriden but by default is based on the current
dir or its first parent that contains one fo the files specified
in the space-separated list in `LOCAL_DIR_ANCHORS`, which can be
overriden itself, but defaults to `.hg .git .configure.ac`.  This
helps an rbuild command issued from inside a subdirectory of the
project, to find the project root directory (the `LOCAL_DIR`).

autoconf-based projects require a one-time setup before building.
This can be performed on the build server by hand after `rbuild -s` and
before the first `rbuild -b`. Typically this requires running `autoreconf --install`
in the remote staging directory `STAGING_DIR`, and
`configure --prefix $INSTALL_DIR` in the remote build dir, as specified
by `BUILD_DIR` described later.

The following shortcuts can be used instead of the manual method:

* `rbuild -A` runs `autoreconf --install` in the remote source directory.
* `rbuild -a` runs `configure --prefix=$INSTALL_DIR` in the remote build directory.

The environment variables passed to `configure` by default are `CC`, `CFLAGS`
and `PKG_CONFIG_PATH`.  To pass additional variables through `.rbuild.conf`:

    EXTRA_CONFIGURE_VARS="LDFLAGS=-L/usr/local/lib LIBS=\'-lm -lpcap\'"

To pass additional command line options to `configure`:

    EXTRA_CONFIGURE_ARGS='--enable-optimizations'

To set environment variables for `make` use `BUILD_VARS`, for example:

    BUILD_VARS="GIT_REVISION=$(git rev-parse HEAD)"

The remote build directory on `BUILD_HOST` is `BUILD_DIR`.
It could be specified in the config file, but the default 
of `RBUILD_DIR/BASENAME.BUILD_ENV` can be used too. `BUILD_ENV` defaults to `debug` but
can be specified on the rbuild command line using `-e`. The value of
`BUILD_ENV` can be used inside `.rbuild.conf` to customize the build,
as can be seen in the provided `sample.rbuild.conf`.

`INSTALL_DIR` defaults to `'$HOME/.local'`. Note that `$HOME` on
the local machine and the remote build host may differ. Using single
quotes ensures that the `$HOME` variable is evaluated on the remote
machine.

`rbuild -b` performs `make install` in `BUILD_DIR` on the `BUILD_HOST`.

Other command line options include:

* `-c` to run `make clean` in the build dir
* `-t` to run `make check` in the build dir
* `-r` to completely remove the build dir
* `-j` to control the -j argument of make
* `-o` is a shortcut to `-e optimized`
* `-S` copies the source code to the `DEPLOY_HOST` (useful for remote GDB)
* `-R` removes the source code from the `DEPLOY_HOST`
* `-x` dump the contents of the built-in rsync file exclusion list
* `-B` build a specific makefile target


Multiple flags can be combined, e.g. `rbuild -sAabod`. 
Any operation specified in the command line is executed
in this order independently of its position:

1. Stage
1. Clean
1. Autoreconf
1. Configure
1. Make
1. Deploy
1. Deploy source

## rsync exclude list

If `autoreconf` has been run on the remote source directory, its generated
files would be clobbered by a subsequent `rbuild -s`. To avoid this, `rbuild`
supports an rsync exclude list passed to rsync via its `--exclude-file`
option. `rbuild` will look for this list with this order:

1. `$LOCAL_DIR/.rbuild_exclude`
1. `$HOME/.rbuild.exclude`
1. Use a built-in list which can be inspected by running `rbuild -x`

If `autoreconf` is not required, or if it is performed on the local machine,
use of the exclude list is not required and can be disabled using an empty
exclusion list file.

## Vim integration

rbuild arranges for the filenames in the build output to use relative
paths, so that they can be used by a local editor. For example,
with Vim we can specify `set makeprg=rbuild` to invoke rbuild using
`:make` and use Vim to navigate the results. Vim plugins that are
useful in combination with rbuild include `vim-dispatch` that can
allows background build with tmux, and `vim-addon-local-vimrc` for
per-project `.vimrc` files.


## Deploying to a third machine

rbuild can be used to deploy the built binaries from the remote
build host to another remote host that lacks a development environment.
The command `rbuild -d` runs rsync on the build host to sync
`INSTALL_DIR` to the machine specified in `DEPLOY_HOST`.  `INSTALL_DIR`
must be valid on the deploy host (any missing directories will be
created) and `DEPLOY_HOST` must be usable as an SSH host on
`BUILD_HOST`.  The transfer is performed between the two remote
machines, using rsync.
