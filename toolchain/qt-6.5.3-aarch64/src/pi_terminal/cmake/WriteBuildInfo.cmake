# 生成 build-info.h：把「这次构建发生在哪一天」写进程序。
#
# 与 __DATE__ 的区别：__DATE__ 只在包含它的编译单元重编时才变，
# 只改 QML 的增量构建会让日期停在旧值。这里由 CMake 在**每次构建**时
# 重新计算日期，内容不变则不写文件，避免无谓的重编与重链接。
#
# 用法：cmake -DOUT=<build-info.h 路径> -P WriteBuildInfo.cmake

if(NOT DEFINED OUT OR OUT STREQUAL "")
    message(FATAL_ERROR "WriteBuildInfo.cmake: OUT 未设置")
endif()

# 用本地时间：界面上的 build 日期应与使用者看到的日历一致。
string(TIMESTAMP BUILD_DATE "%Y-%m-%d")

set(CONTENT "// 由 cmake/WriteBuildInfo.cmake 在每次构建时生成，请勿手改。\n#pragma once\n#define ORANGE_PI_BUILD_DATE \"${BUILD_DATE}\"\n")

if(EXISTS "${OUT}")
    file(READ "${OUT}" EXISTING)
    if(EXISTING STREQUAL CONTENT)
        return()
    endif()
endif()

file(WRITE "${OUT}" "${CONTENT}")
