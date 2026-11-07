# Qt 6.5.3 / pi_terminal 的 aarch64 交叉编译工具链
# 用法：cmake -DCMAKE_TOOLCHAIN_FILE=cross-build/toolchain-pi653.cmake ...
# 依赖环境变量：ORPI_SYSROOT（Pi Debian 12 的 aarch64 sysroot 路径）
#              ORPI_QT_PREFIX（Qt 6.5.3 aarch64 安装前缀）
#              ORPI_HOST_QT（Qt 6.5.3 x86_64 host SDK）
#              ORPI_STUB（isoc23_compat.o 的绝对路径，由 build 脚本生成）

if(NOT DEFINED ENV{ORPI_SYSROOT})
  message(FATAL_ERROR "请先 export ORPI_SYSROOT=/path/to/pi-sysroot")
endif()
set(_SYSROOT $ENV{ORPI_SYSROOT})
set(_PREFIX $ENV{ORPI_QT_PREFIX})
set(_HOST $ENV{ORPI_HOST_QT})
set(_STUB $ENV{ORPI_STUB})

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER   $ENV{ORPI_CROSS_PREFIX}gcc)
set(CMAKE_CXX_COMPILER $ENV{ORPI_CROSS_PREFIX}g++)
set(CMAKE_SYSROOT ${_SYSROOT})
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)
set(CMAKE_FIND_ROOT_PATH ${_SYSROOT} ${_PREFIX})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
if(_HOST)
  set(QT_HOST_PATH ${_HOST} CACHE PATH "" FORCE)
endif()
if(_PREFIX)
  set(CMAKE_PREFIX_PATH ${_PREFIX} CACHE STRING "" FORCE)
endif()

# 关键：宿主交叉 gcc 的 /usr/aarch64-linux-gnu/{include,lib}（glibc 2.39）排在 sysroot（2.36）之前。
#  1) 头文件侧会让 C++ 引用 __isoc23_*  -> 用 isoc23_compat.o 补符号
#  2) 库侧会让链接记录 GLIBC_2.38 需求 -> 用 -L 把 sysroot 的 libc/libm 提到最前
# 缺任何一项，产物在 Pi（glibc 2.36）上都会报 version `GLIBC_2.38' not found。
set(_SYS_LIBS "-L${_SYSROOT}/usr/lib/aarch64-linux-gnu -L${_SYSROOT}/lib/aarch64-linux-gnu")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${_SYS_LIBS} ${_STUB}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_SYS_LIBS} ${_STUB}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${_SYS_LIBS} ${_STUB}")
