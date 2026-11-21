# 模块 aarch64 交叉工具链（module-devkit 自带）
#
# 用法：
#   cmake -S <模块目录> -B build \
#         -DCMAKE_TOOLCHAIN_FILE=<devkit>/toolchain/module-aarch64.cmake \
#         -DMODULE_SDK_DIR=<devkit>/sdk
#
# 三件套（Qt 6.5.3 aarch64 / 宿主 Qt / Debian 12 aarch64 sysroot）按下列顺序探测：
#   1. 环境变量 ORPI_QT_PREFIX、ORPI_HOST_QT、ORPI_SYSROOT
#   2. $ORPI_SDK_ROOT 或 <仓库根>/dist/sdk 下的 qt653-arm64、host-qt、pi-sysroot
#
# 设计约束（改这个文件前先读）：
#   - 幂等：toolchain 在 configure 期间可能被求值多次，所有 *_INIT 用 set 不用
#     string(APPEND)，否则 isoc23 桩会被注入两遍，链接报 multiple definition。
#   - 不写死绝对 RUNPATH：模块运行在 target 上，Qt 由宿主进程解析；把开发机
#     路径写进 RUNPATH 只会在目标机上失效。
#   - Qt 必须是 6.5.x：全项目基线 6.5.3，6.4.x 已不支持（见仓库 AGENTS.md）。

if(NOT DEFINED ENV{ORPI_SYSROOT} AND NOT DEFINED ENV{ORPI_SDK_ROOT})
  # 允许通过 -DORPI_SDK_ROOT=... 传入；环境变量优先便于 CI。
  if(DEFINED ORPI_SDK_ROOT)
    set(ENV{ORPI_SDK_ROOT} "${ORPI_SDK_ROOT}")
  endif()
endif()

# ---------- 仓库根与三件套探测 ----------
get_filename_component(_DEVKIT_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
get_filename_component(_REPO_ROOT "${_DEVKIT_DIR}/.." ABSOLUTE)

set(_SDK_CANDIDATES "")
if(DEFINED ENV{ORPI_SDK_ROOT} AND NOT "$ENV{ORPI_SDK_ROOT}" STREQUAL "")
  list(APPEND _SDK_CANDIDATES "$ENV{ORPI_SDK_ROOT}")
endif()
# devkit 可能出现在三个位置，三件套也可能放在 devkit 旁边或仓库根的 dist/sdk：
#   <仓库根>/module-devkit            （主 devkit）
#   旧 SDK 快照里的 module-devkit（兼容探测）
#   <任意目录>/module-devkit          （独立 SDK，使用者自己放 dist/sdk）
list(APPEND _SDK_CANDIDATES "${_DEVKIT_DIR}/dist/sdk")
set(_probe "${_DEVKIT_DIR}")
foreach(_depth RANGE 1 4)
  get_filename_component(_probe "${_probe}/.." ABSOLUTE)
  list(APPEND _SDK_CANDIDATES "${_probe}/dist/sdk")
endforeach()

set(_SDK_ROOT "")
foreach(_c ${_SDK_CANDIDATES})
  if(EXISTS "${_c}/qt653-arm64" OR EXISTS "${_c}/orpi-qt653-aarch64-dev")
    set(_SDK_ROOT "${_c}")
    break()
  endif()
endforeach()

function(_devkit_pick out_var)
  if(DEFINED ENV{${out_var}} AND NOT "$ENV{${out_var}}" STREQUAL "")
    set(${out_var} "$ENV{${out_var}}" PARENT_SCOPE)
    return()
  endif()
  foreach(_p ${ARGN})
    if(EXISTS "${_p}")
      set(${out_var} "${_p}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  set(${out_var} "" PARENT_SCOPE)
endfunction()

if(_SDK_ROOT)
  _devkit_pick(_QT_PREFIX
               "${_SDK_ROOT}/qt653-arm64"
               "${_SDK_ROOT}/orpi-qt653-aarch64-dev")
  _devkit_pick(_HOST_QT   "${_SDK_ROOT}/host-qt")
  _devkit_pick(_SYSROOT   "${_SDK_ROOT}/pi-sysroot")
else()
  _devkit_pick(_QT_PREFIX "$ENV{ORPI_QT_PREFIX}")
  _devkit_pick(_HOST_QT   "$ENV{ORPI_HOST_QT}")
  _devkit_pick(_SYSROOT   "$ENV{ORPI_SYSROOT}")
endif()
_devkit_pick(_STUB
             "$ENV{ORPI_STUB}"
             "${_DEVKIT_DIR}/../toolchain/qt-6.5.3-aarch64/cross-build/build/isoc23_compat.o")

# ---------- 交叉编译器 ----------
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

find_program(_AARCH64_GCC NAMES aarch64-linux-gnu-gcc-12 aarch64-linux-gnu-gcc REQUIRED)
find_program(_AARCH64_GXX NAMES aarch64-linux-gnu-g++-12 aarch64-linux-gnu-g++ REQUIRED)
set(CMAKE_C_COMPILER   "${_AARCH64_GCC}" CACHE FILEPATH "" FORCE)
set(CMAKE_CXX_COMPILER "${_AARCH64_GXX}" CACHE FILEPATH "" FORCE)

# ---------- sysroot 与查找根 ----------
if(NOT _SYSROOT)
  message(FATAL_ERROR
    "找不到 aarch64 sysroot。请设置 ORPI_SYSROOT，或把 Debian 12 sysroot 放到 "
    "<仓库根>/dist/sdk/pi-sysroot。")
endif()
set(CMAKE_SYSROOT "${_SYSROOT}")
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)
set(CMAKE_FIND_ROOT_PATH "${_SYSROOT}")
if(_QT_PREFIX)
  list(APPEND CMAKE_FIND_ROOT_PATH "${_QT_PREFIX}")
  set(CMAKE_PREFIX_PATH "${_QT_PREFIX}" CACHE PATH "" FORCE)
endif()
if(_HOST_QT)
  set(QT_HOST_PATH "${_HOST_QT}" CACHE PATH "" FORCE)
endif()
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# ---------- Qt 6.5.x 基线校验 ----------
# qconfig.pri 是纯文本，不需要执行 aarch64 的 qmake，因此交叉环境下可读。
if(_QT_PREFIX AND EXISTS "${_QT_PREFIX}/mkspecs/qconfig.pri")
  file(STRINGS "${_QT_PREFIX}/mkspecs/qconfig.pri" _qtver_line REGEX "^QT_VERSION[ \t]*=")
  if(_qtver_line)
    string(REGEX REPLACE "^QT_VERSION[ \t]*=[ \t]*" "" _QT_VERSION "${_qtver_line}")
    string(STRIP "${_QT_VERSION}" _QT_VERSION)
    if(_QT_VERSION VERSION_LESS 6.5.0)
      message(FATAL_ERROR
        "交叉 SDK 里的 Qt 是 ${_QT_VERSION}，低于项目基线 6.5.x。"
        " 全项目已统一到 Qt 6.5.3，6.4.x 不再支持；不要把 --toolchain 指向板端系统 Qt。")
    endif()
    message(STATUS "module-devkit: 交叉 Qt ${_QT_VERSION} (${_QT_PREFIX})")
  endif()
endif()
if(NOT _QT_PREFIX)
  message(WARNING
    "module-devkit: 未找到 aarch64 Qt 6.5.3 开发树。只有不链接 Qt 的模块能编过；"
    "需要 Qt 的模块请设置 ORPI_QT_PREFIX 或准备 <仓库根>/dist/sdk/qt653-arm64。")
endif()

# ---------- 链接器：sysroot 库优先 + isoc23 兼容桩 ----------
# 宿主 aarch64 交叉包的 glibc（2.39）排在 sysroot（2.36）之前时：
#   1) 头文件侧让 C++ 引用 __isoc23_*  -> 用 isoc23_compat.o 补符号
#   2) 库侧链接记录 GLIBC_2.38 需求    -> 用 -L 把 sysroot 的 libc/libm 提前
# 缺任何一项，产物在目标板（glibc 2.36）上都报 version `GLIBC_2.38' not found。
set(_SYS_LIBS "-L${_SYSROOT}/usr/lib/aarch64-linux-gnu -L${_SYSROOT}/lib/aarch64-linux-gnu")
set(_STUB_FLAGS "")
if(_STUB AND EXISTS "${_STUB}")
  set(_STUB_FLAGS "${_STUB}")
elseif(_STUB)
  message(WARNING
    "module-devkit: isoc23 兼容桩 ${_STUB} 不存在。若目标板报 GLIBC_2.38 缺失，"
    "用 aarch64 gcc --sysroot 编译仓库里的 cross-build/isoc23_compat.c 生成它。")
endif()
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${_SYS_LIBS} ${_STUB_FLAGS}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_SYS_LIBS} ${_STUB_FLAGS}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${_SYS_LIBS} ${_STUB_FLAGS}")

# ---------- 产物不带开发机路径 ----------
# 模块 .so 在目标机上由宿主进程加载；宿主自己的 RUNPATH/LD_LIBRARY_PATH 决定
# Qt 从哪里来。把开发机绝对路径写进模块 RUNPATH 只会让目标机加载失败。
set(CMAKE_SKIP_BUILD_RPATH TRUE)
set(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE)
set(CMAKE_INSTALL_RPATH "")
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH FALSE)
