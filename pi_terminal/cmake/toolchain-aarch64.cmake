# 仓库内的 aarch64 交叉工具链入口：只读环境变量，不写死任何人的家目录。
#
#   export ORPI_SYSROOT=/path/to/pi-sysroot        # Debian 12 aarch64
#   export ORPI_QT_PREFIX=/path/to/qt653-arm64     # Qt 6.5.3 aarch64
#   cmake --preset aarch64-cross
#
# 与 toolchain/qt-6.5.3-aarch64 配合使用；该仓库的 deploy/env.sh 会导出上面两个变量。
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

find_program(AARCH64_GCC NAMES aarch64-linux-gnu-gcc-12 aarch64-linux-gnu-gcc REQUIRED)
find_program(AARCH64_GXX NAMES aarch64-linux-gnu-g++-12 aarch64-linux-gnu-g++ REQUIRED)
set(CMAKE_C_COMPILER   "${AARCH64_GCC}" CACHE FILEPATH "")
set(CMAKE_CXX_COMPILER "${AARCH64_GXX}" CACHE FILEPATH "")

if(DEFINED ENV{ORPI_SYSROOT})
    set(CMAKE_SYSROOT "$ENV{ORPI_SYSROOT}")
    set(CMAKE_FIND_ROOT_PATH "$ENV{ORPI_SYSROOT}")
    if(DEFINED ENV{ORPI_QT_PREFIX})
        list(APPEND CMAKE_FIND_ROOT_PATH "$ENV{ORPI_QT_PREFIX}")
        set(CMAKE_PREFIX_PATH "$ENV{ORPI_QT_PREFIX}" CACHE PATH "")
    endif()
    set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
    set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
    set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
    set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
    if(DEFINED ENV{ORPI_PKG_CONFIG_LIBDIR})
        set(ENV{PKG_CONFIG_LIBDIR} "$ENV{ORPI_PKG_CONFIG_LIBDIR}")
    elseif(EXISTS "$ENV{ORPI_SYSROOT}/usr/lib/pkgconfig")
        set(ENV{PKG_CONFIG_LIBDIR}
            "$ENV{ORPI_SYSROOT}/usr/lib/pkgconfig:$ENV{ORPI_SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:$ENV{ORPI_SYSROOT}/usr/share/pkgconfig")
        set(ENV{PKG_CONFIG_SYSROOT_DIR} "$ENV{ORPI_SYSROOT}")
    endif()
endif()

if(DEFINED ENV{ORPI_HOST_QT})
    set(QT_HOST_PATH "$ENV{ORPI_HOST_QT}" CACHE PATH "")
endif()
