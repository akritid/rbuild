# rbuild: Edit locally, build remotely

rbuild is a simple script to support the workflow of editing C source code
on a local machine (e.g. a macOS laptop with MacVim), syncing the
source code to a remote build machine with full development environment
(e.g. a Linux server). It can also be used to sync the generated binaries to a
third machine without a development environment.

In the normal rbuild workflow, the developer edits locally, and
runs `rbuild -s` to stage the source code to the build machine and
`rbuild -b` to perform a remote build. These can be combined into
`rbuild -sb`, which are also the default options when running rbuild
without any arguments. rbuild requires a configuration file found
in `$HOME/.rbuild.conf` or provided using the `-C` option. This file
needs to include a `BUILD_HOST` variable.

`rbuild -s` stages the source code from `LOCAL_DIR` to
`BUILD_HOST:RBUILD_DIR\BASENAME` using rsync. `RBUILD_DIR` and `BASENAME` can be overriden,
but by default `RBUILD_DIR` is `rbuild` and `BASENAME` is the
basename of `LOCAL_DIR`. `LOCAL_DIR` can be overriden but by default
is based on the current dir or its first parent that contains one
fo the files specified in the space-separated list in `LOCAL_DIR_ANCHORS`,
which can be overriden itself, but defaults to `.hg .git .configure.ac`.
This helps an rbuild command issued from inside a subdirectory of
the project, to find the project root directory (the `LOCAL_DIR`).

autoconf-based projects require a one-time setup is required before building.
This can be performed on the build server by hand after `rbuild -s` and
before the first `rbuild -b`, or the following shortcuts can be used:

* `rbuild -A` runs `autoreconf --install` in the remote source directory.
* `rbuild -a` runs `configure --prefix=$INSTALL_DIR` in the remote build directory.

`rbuild -b` performs `make install` in `BUILD_DIR` on the `BUILD_HOST`.
`BUILD_DIR` can be provided, but the default can be used which is created
from `RBUILD_DIR/BASENAME.BUILD_ENV`. `BUILD_ENV` defaults to `debug` but
can be specified on the rbuild command line using `-e`. The value of
`BUILD_ENV` can be used inside `.rbuild.conf` to customize the build,
as can be seen in the provided `sample.rbuild.conf`.

Other command line options include:

* `-c` to run `make clean` in the build dir
* `-j` to control the -j argument of make
* `-o` is a shortcut to `-e optimized`
* `-S` copies the source code to the `DEPLOY_HOST` (useful for remote GDB)
* `-R` removes the source code from the `DEPLOY_HOST`
* `-x` dump the contents of the built-in rsync file exclusion list
* `-B` build a specific makefile target


Multiple flags can be combined, e.g. `rbuild -sAabod`. The order of the
operations is fixed and does not depend on the order of the command line options:

* Stage
* Clean
* Autoreconf
* Configure
* Make
* Deploy
* Deploy source

## rsync exclude list

If `autoreconf` has been run on the remote source directory, its generated
files would be clobbered by a subsequent `rbuild -s`. To avoid this, `rbuild`
supports an rsync exclude list passed to rsync via its `--exclude-file`
option. `rbuild` will look for this list with this order:

* `$LOCAL_DIR/.rbuild_exclude`
* `$HOME/.rbuild.exclude`
* Use a built-in list which can be inspected by running `rbuild -x`

If `autoreconf` is not required, or if it is performed on the local machine,
use of the exclude list is not required and can be disabled using an empty
exclusion list file.

## Vim

rbuild arranges for the filenames in the build output to use relative
paths, so that they can be used by a local editor. For example,
with Vim we can specify `set makeprg=rbuild` to invoke rbuild using
`:make` and use Vim to navigate the results. Vim plugins that are
useful in combination with rbuild include `vim-dispatch` that can
allows background build with tmux, and `vim-addon-local-vimrc` for
per-project `.vimrc` files.


## Deploying

rbuild can be used to deploy the built binaries from the remote
build host to another remote host that lacks a development environment.
The command `rbuild -d` runs rsync on the build host to sync
`INSTALL_DIR` to the machine specified in `DEPLOY_HOST`.  `INSTALL_DIR`
must be valid on the deploy host (any missing directories will be
created) and `DEPLOY_HOST` must be usable as an SSH host on
`BUILD_HOST`.  The transfer is performed between the two remote
machines, using rsync.
