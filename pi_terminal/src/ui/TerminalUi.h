#pragma once

// Strong reference to the UI library also retains its QML/font/icon resources
// when the executable is linked with --as-needed.
void initializeTerminalUi();

// True when this build ships the libVLC video backend (VlcPlayer/VlcVideoOutput
// types are registered and VideoPlayer can select the VLC path).
#ifdef TERMINAL_VLC_BACKEND
inline bool terminalVlcBackendAvailable() { return true; }
#else
inline bool terminalVlcBackendAvailable() { return false; }
#endif
