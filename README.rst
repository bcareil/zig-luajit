zig-luajit
==========

Zig bindings for luajit.

The luajit build process has been ported to zig build system to try and support
cross compilation for all targets supported by both projects.

Currently, this has only been tested on OSX and Linux. But bug reports and pull
requests about the other platforms are welcome.

The bindings will stay as is (i.e., only leveraging ``@cImport``) as existing
projects already provide a good abstraction layer over the plain C functions.

I recommend to use this project together with `zoltan`_ if a more zig friendly API
is desired.

.. _zoltan: https://github.com/ranciere/zoltan

Licensing
---------

While the work in this repository is under Boost Source License unless otherwise
stated (such as in the ``myscript.lua`` file), the luajit's license need to be
properly reproduced as well.
