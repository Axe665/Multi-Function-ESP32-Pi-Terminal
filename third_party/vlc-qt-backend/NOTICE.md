# NOTICE

This directory (`third_party/vlc-qt-backend`) contains original code written for
the terminal project: a thin Qt Quick wrapper around the system libVLC library
(https://www.videolan.org/vlc/libvlc.html).

No third-party source code is vendored here. libVLC itself is an external
runtime dependency located on the build machine (see README.md); it is linked
dynamically and is distributed under its own license (LGPL-2.1-or-later).

The code in this directory is licensed under the same terms as the terminal
project that consumes it.
