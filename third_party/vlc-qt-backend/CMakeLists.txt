cmake_minimum_required(VERSION 3.21)
project(vlc_qt_backend LANGUAGES CXX)

# Standalone builds (cmake -S third_party/vlc-qt-backend ...) also get ctest
# registration; harmless when consumed via add_subdirectory from a parent that
# already included CTest.
include(CTest)

# QML-facing libVLC playback backend for Qt Quick.
#
# Portability contract:
#   * The library ALWAYS builds, on every development platform, even without
#     libVLC: when libvlc is not found the sources compile a stub VlcPlayer
#     (same QML surface, immediate "runtime unavailable" error). The QML types
#     are still registered and the host application keeps its Qt Multimedia
#     fallback. See VlcBackendInfo.h -> vlcBackendAvailable().
#   * libvlc is located via pkg-config first, or manually via the cache
#     variables LIBVLC_INCLUDE_DIR / LIBVLC_LIBRARY (Windows/macOS/vcpkg).
set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.4 REQUIRED COMPONENTS Core Gui Qml Quick)

option(VLC_BACKEND_ENABLED "Detect libvlc and build the real VLC backend" ON)
set(VLC_BACKEND_HAVE_LIBVLC FALSE)

if(VLC_BACKEND_ENABLED)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
        pkg_check_modules(LIBVLC QUIET IMPORTED_TARGET libvlc)
        if(LIBVLC_FOUND)
            set(VLC_BACKEND_HAVE_LIBVLC TRUE)
        endif()
    endif()
    if(NOT VLC_BACKEND_HAVE_LIBVLC AND LIBVLC_INCLUDE_DIR AND LIBVLC_LIBRARY)
        # Manual override for platforms without pkg-config (Windows, macOS,
        # custom sysroots). Point at the include dir and the libvlc library.
        add_library(libvlc_manual SHARED IMPORTED GLOBAL)
        set_target_properties(libvlc_manual PROPERTIES
            IMPORTED_LOCATION "${LIBVLC_LIBRARY}"
            INTERFACE_INCLUDE_DIRECTORIES "${LIBVLC_INCLUDE_DIR}")
        add_library(PkgConfig::LIBVLC ALIAS libvlc_manual)
        set(VLC_BACKEND_HAVE_LIBVLC TRUE)
    endif()
endif()

add_library(vlc_qt_backend STATIC
    src/VlcPlayer.cpp
    src/VlcVideoOutput.cpp
    include/vlc-qt-backend/VlcPlayer.h
    include/vlc-qt-backend/VlcVideoOutput.h
    include/vlc-qt-backend/VlcBackendInfo.h)
add_library(vlc-qt-backend::vlc-qt-backend ALIAS vlc_qt_backend)
target_include_directories(vlc_qt_backend PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_link_libraries(vlc_qt_backend PUBLIC Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick)
if(VLC_BACKEND_HAVE_LIBVLC)
    target_link_libraries(vlc_qt_backend PRIVATE PkgConfig::LIBVLC)
    target_compile_definitions(vlc_qt_backend PUBLIC VLC_BACKEND_HAVE_LIBVLC)
    message(STATUS "vlc-qt-backend: libvlc FOUND — real VLC playback enabled")
else()
    message(STATUS "vlc-qt-backend: libvlc NOT FOUND — stub backend built, Qt Multimedia fallback stays active")
endif()

if(BUILD_TESTING)
    find_package(Qt6 6.4 REQUIRED COMPONENTS Test)
    add_executable(vlc_player_function_test tests/vlc_player_function_test.cpp)
    target_link_libraries(vlc_player_function_test PRIVATE vlc-qt-backend::vlc-qt-backend Qt6::Test)
    add_test(NAME vlc_player_function COMMAND vlc_player_function_test)
    set_tests_properties(vlc_player_function PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 60)

    add_executable(vlc_player_performance_test tests/vlc_player_performance_test.cpp)
    target_link_libraries(vlc_player_performance_test PRIVATE vlc-qt-backend::vlc-qt-backend Qt6::Test Qt6::Quick)
    add_test(NAME vlc_player_performance COMMAND vlc_player_performance_test)
    set_tests_properties(vlc_player_performance PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software" TIMEOUT 180)
endif()
