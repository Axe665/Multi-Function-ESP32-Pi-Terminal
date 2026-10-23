#pragma once

// Build-time capability flag for the vlc-qt-backend library.
//
// VLC_BACKEND_HAVE_LIBVLC is defined (by the library's CMake target) only when
// libvlc was located at configure time. When it is absent the library compiles
// a stub VlcPlayer with the identical QML surface: the host application keeps
// compiling on every development platform, VlcPlayer reports an immediate
// "runtime unavailable" error, and the Qt Multimedia fallback stays active.
#ifdef VLC_BACKEND_HAVE_LIBVLC
inline bool vlcBackendAvailable() { return true; }
#else
inline bool vlcBackendAvailable() { return false; }
#endif
