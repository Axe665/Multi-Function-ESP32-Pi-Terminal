cmake_minimum_required(VERSION 3.21)
project(orange_pi_terminal VERSION 1.0 LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
include(CTest)
include(GNUInstallDirs)
option(TERMINAL_REPAIR_AUDIT "Enable explicit hardware screenshot regression harness" OFF)
add_library(pi_module_sdk INTERFACE)
add_library(OrangePi::ModuleSDK ALIAS pi_module_sdk)
set_target_properties(pi_module_sdk PROPERTIES EXPORT_NAME ModuleSDK)
target_include_directories(pi_module_sdk INTERFACE $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src/modules/api> $<INSTALL_INTERFACE:include/orange-pi-terminal>)
target_compile_features(pi_module_sdk INTERFACE cxx_std_17)
find_package(Qt6 6.4 REQUIRED COMPONENTS Core Gui Widgets Network Bluetooth Qml Quick QuickControls2 SerialPort OpenGL WebEngineQuick WebEngineWidgets WebEngineCore QuickWidgets WebChannel Concurrent Svg PrintSupport Multimedia TextToSpeech StateMachine)
find_package(Qt6 6.4 REQUIRED COMPONENTS ShaderTools)
# 内置依赖前缀：third_party/vendor/deps（OpenSSL / mbedTLS / SQLCipher）。
# 仓库里带了这套开发文件，别人 clone 后不用装系统开发包；不存在时回落到系统路径。
set(TERMINAL_VENDOR_DEPS "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vendor/deps")
if(NOT CMAKE_CROSSCOMPILING AND EXISTS "${TERMINAL_VENDOR_DEPS}/include")
    list(APPEND CMAKE_PREFIX_PATH "${TERMINAL_VENDOR_DEPS}")
    list(APPEND CMAKE_LIBRARY_PATH "${TERMINAL_VENDOR_DEPS}/lib/x86_64-linux-gnu")
    list(APPEND CMAKE_INCLUDE_PATH "${TERMINAL_VENDOR_DEPS}/include")
    set(OPENSSL_ROOT_DIR "${TERMINAL_VENDOR_DEPS}")
    set(OPENSSL_INCLUDE_DIR "${TERMINAL_VENDOR_DEPS}/include")
    set(OPENSSL_CRYPTO_LIBRARY "${TERMINAL_VENDOR_DEPS}/lib/x86_64-linux-gnu/libcrypto.so")
    set(OPENSSL_SSL_LIBRARY "${TERMINAL_VENDOR_DEPS}/lib/x86_64-linux-gnu/libssl.so")
    set(SQLCIPHER_ROOT "${TERMINAL_VENDOR_DEPS}")
elseif(CMAKE_CROSSCOMPILING)
    # Cross build: use the target sysroot, never the x86_64 vendor binaries.
    set(OPENSSL_ROOT_DIR "${CMAKE_SYSROOT}/usr")
    set(OPENSSL_INCLUDE_DIR "${CMAKE_SYSROOT}/usr/include")
    set(SQLCIPHER_ROOT "${CMAKE_SYSROOT}/usr")
endif()

# PBR AEAD（T-07）与 PIN/DB key 封装都用 OpenSSL，早期就要找到。
find_package(OpenSSL REQUIRED COMPONENTS Crypto)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vlc
                 ${CMAKE_CURRENT_BINARY_DIR}/third_party/vlc)
set(VIPER_EMBEDDED ON CACHE BOOL "Build the Viper browser engine as embedded terminal components" FORCE)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../third_party/Viper-Browser
                 ${CMAKE_CURRENT_BINARY_DIR}/third_party/Viper-Browser)
if(BUILD_TESTING)
    find_package(Qt6 6.4 REQUIRED COMPONENTS Test)
endif()
add_library(terminal_protocol STATIC
    src/protocol/pibridge_protocol.cpp
    src/protocol/pibridge_protocol.h
    src/protocol/control_event.cpp
    src/protocol/control_event.h
    src/protocol/pbr_aead.cpp src/protocol/pbr_aead.h
    src/protocol/pbr_session.cpp src/protocol/pbr_session.h
    src/protocol/pbr_handshake.cpp src/protocol/pbr_handshake.h
    src/protocol/data_checksum.h)
target_include_directories(terminal_protocol PUBLIC src)
target_link_libraries(terminal_protocol PUBLIC Qt6::Core OpenSSL::Crypto)
target_compile_options(terminal_protocol PRIVATE -Wall -Wextra -Wpedantic)

# 物理槽位路由：纯 Qt Core，不依赖网络/蓝牙，便于单测。
# terminal_core 依赖它，但它不反向依赖 terminal_core。
add_library(terminal_routing STATIC
    src/core/SlotRouter.cpp src/core/SlotRouter.h)
target_include_directories(terminal_routing PUBLIC src)
target_link_libraries(terminal_routing PUBLIC Qt6::Core)
target_compile_options(terminal_routing PRIVATE -Wall -Wextra -Wpedantic)

set(TERMINAL_SECURITY_SOURCES
    # KDF 子进程客户端：把耗时计算挪出主线程（进程隔离）
    src/security/KdfClient.cpp src/security/KdfClient.h
    # D 侧：身份、信任库、UID 索引
    src/security/TrustStore.cpp src/security/TrustStore.h
    src/protocol/uid_index.cpp src/protocol/uid_index.h
    # Z 侧：用户/PIN/会话/存储/卡匹配（uid_index_key.cpp 为 uidIndexKey 的唯一实现）
    src/security/uid_index_key.cpp src/security/uid_index_key.h
    src/security/PinPolicy.cpp src/security/PinPolicy.h
    src/security/KeyWrap.cpp src/security/KeyWrap.h
    src/security/UserService.cpp src/security/UserService.h
    src/security/AuthService.cpp src/security/AuthService.h
    src/security/SessionManager.cpp src/security/SessionManager.h
    src/security/TaskCapability.cpp src/security/TaskCapability.h
    src/security/CardMatcher.cpp src/security/CardMatcher.h src/security/CardIndex.h
    src/security/SqlCipherStore.cpp src/security/SqlCipherStore.h
    src/security/UserDatabase.cpp src/security/UserDatabase.h
    src/security/AuditLog.cpp src/security/AuditLog.h
    src/security/PermissionMatrix.cpp src/security/PermissionMatrix.h
    src/security/Backup.cpp src/security/Backup.h
    src/security/RecoveryCode.cpp src/security/RecoveryCode.h)

# 只有 HostIdentity（ECDSA P-256）需要 mbedtls。缺失时跳过该文件，
# 其余安全组件照常构建。CI 上缺 mbedtls 会让身份用例静默消失，需在下游显式断言。
if(CMAKE_CROSSCOMPILING)
    set(MBEDTLS_ROOT "${CMAKE_SYSROOT}/usr" CACHE PATH "mbedtls install prefix (contains include/ and lib/)")
else()
    set(MBEDTLS_ROOT "${TERMINAL_VENDOR_DEPS}" CACHE PATH "mbedtls install prefix (contains include/ and lib/)")
endif()
find_path(MBEDTLS_INCLUDE_DIR mbedtls/ecdsa.h HINTS "${MBEDTLS_ROOT}/include")
find_library(MBEDTLS_CRYPTO_LIBRARY NAMES mbedcrypto HINTS "${MBEDTLS_ROOT}/lib" "${MBEDTLS_ROOT}/lib/x86_64-linux-gnu" "${MBEDTLS_ROOT}/lib/${CMAKE_LIBRARY_ARCHITECTURE}")
if(MBEDTLS_INCLUDE_DIR AND MBEDTLS_CRYPTO_LIBRARY)
    message(STATUS "pbr: mbedtls found at ${MBEDTLS_INCLUDE_DIR} -> HostIdentity enabled (T-03b)")
    list(APPEND TERMINAL_SECURITY_SOURCES src/security/HostIdentity.cpp src/security/HostIdentity.h)
    set(TERMINAL_SECURITY_HAVE_MBEDTLS ON)
else()
    message(STATUS "pbr: mbedtls not found -> HostIdentity (T-03b) skipped; pass -DMBEDTLS_ROOT=... to enable")
    set(TERMINAL_SECURITY_HAVE_MBEDTLS OFF)
endif()

# SQLCipher 路线由 F 裁决（§0.1）：直接调 C API，不走 Qt SQL 插件。
# 找不到库时必须 FATAL_ERROR —— 不得静默降级成普通 SQLite。
find_library(SQLCIPHER_LIB NAMES sqlcipher
    HINTS ${SQLCIPHER_ROOT}/lib ${SQLCIPHER_ROOT}/lib/x86_64-linux-gnu ${SQLCIPHER_ROOT}/lib/${CMAKE_LIBRARY_ARCHITECTURE})
find_path(SQLCIPHER_INCLUDE_DIR sqlite3.h
    HINTS ${SQLCIPHER_ROOT}/include ${SQLCIPHER_ROOT}/include/sqlcipher
    PATH_SUFFIXES sqlcipher)
if(NOT SQLCIPHER_LIB OR NOT SQLCIPHER_INCLUDE_DIR)
    message(FATAL_ERROR
        "SQLCipher not found. Install libsqlcipher-dev or set SQLCIPHER_ROOT. "
        "Refusing to fall back to plain SQLite (T-10 requires encryption).")
endif()
message(STATUS "SQLCipher: ${SQLCIPHER_LIB} (headers ${SQLCIPHER_INCLUDE_DIR})")

add_library(terminal_security STATIC ${TERMINAL_SECURITY_SOURCES})
target_include_directories(terminal_security PUBLIC src)
target_link_libraries(terminal_security
    PUBLIC Qt6::Core Qt6::Gui Qt6::Network Qt6::Concurrent OpenSSL::Crypto ${SQLCIPHER_LIB})
target_compile_definitions(terminal_security PRIVATE SQLITE_HAS_CODEC)
target_include_directories(terminal_security PRIVATE ${SQLCIPHER_INCLUDE_DIR})
target_compile_options(terminal_security PRIVATE -Wall -Wextra -Wpedantic)
if(TERMINAL_SECURITY_HAVE_MBEDTLS)
    target_include_directories(terminal_security PRIVATE ${MBEDTLS_INCLUDE_DIR})
    target_link_libraries(terminal_security PUBLIC ${MBEDTLS_CRYPTO_LIBRARY})
endif()

add_library(terminal_transports STATIC
    src/transport/TransportBase.h
    src/transport/PogoControlTransport.cpp src/transport/PogoControlTransport.h
    src/transport/BleTransport.cpp src/transport/BleTransport.h
    src/transport/HotspotLanTransport.cpp src/transport/HotspotLanTransport.h)
target_include_directories(terminal_transports PUBLIC src)
target_link_libraries(terminal_transports PUBLIC terminal_protocol Qt6::Core Qt6::Network Qt6::Bluetooth Qt6::SerialPort)
target_compile_options(terminal_transports PRIVATE -Wall -Wextra -Wpedantic)

# 联网门控：只依赖 Qt Core，单独成一个库，这样 terminal_music / terminal_system /
# terminal_ui 都能链它（它们不链 terminal_core，反向链接会成环）。
add_library(terminal_gate STATIC
    src/core/NetworkGate.cpp src/core/NetworkGate.h)
target_include_directories(terminal_gate PUBLIC src)
target_link_libraries(terminal_gate PUBLIC Qt6::Core)
target_compile_options(terminal_gate PRIVATE -Wall -Wextra -Wpedantic)
# 它会被链进共享库（terminal_music），必须 PIC，否则 aarch64 链接期报
# "dangerous relocation: unsupported relocation"。
set_target_properties(terminal_gate PROPERTIES POSITION_INDEPENDENT_CODE ON)

# 「关于本机」的 build 日期：每次构建由 CMake 重新生成 build-info.h。
# 不用 __DATE__：只改 QML 的增量构建不会重编 main.cpp，日期会停在旧值。
set(ORANGE_PI_BUILD_INFO "${CMAKE_CURRENT_BINARY_DIR}/build-info.h")
if(NOT EXISTS "${ORANGE_PI_BUILD_INFO}")
    file(WRITE "${ORANGE_PI_BUILD_INFO}"
        "// placeholder：首次构建时由 WriteBuildInfo.cmake 覆盖\n#pragma once\n#define ORANGE_PI_BUILD_DATE \"unknown\"\n")
endif()
add_custom_target(build_info ALL
    COMMAND ${CMAKE_COMMAND} "-DOUT=${ORANGE_PI_BUILD_INFO}"
            -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/WriteBuildInfo.cmake"
    BYPRODUCTS "${ORANGE_PI_BUILD_INFO}"
    COMMENT "Stamping build date"
    VERBATIM)

add_library(terminal_core STATIC
    src/core/MachineInfo.cpp src/core/MachineInfo.h
    src/core/DeveloperProbe.cpp src/core/DeveloperProbe.h
    src/core/TestRunner.cpp src/core/TestRunner.h
    src/core/ModuleManager.cpp src/core/ModuleManager.h
    src/core/ConnectionManager.cpp src/core/ConnectionManager.h
    src/core/HostEventDetector.h
    src/core/BridgeConnectionMonitor.h
    src/core/ModuleCardModel.cpp src/core/ModuleCardModel.h
    src/core/PageProvider.cpp src/core/PageProvider.h
    src/core/SessionStateMachine.cpp src/core/SessionStateMachine.h
    src/core/PackageReceiver.cpp src/core/PackageReceiver.h
    src/core/SecurityStatus.cpp src/core/SecurityStatus.h
    src/core/WorkerIpc.cpp src/core/WorkerIpc.h
    src/core/ModuleWorkerLauncher.cpp src/core/ModuleWorkerLauncher.h
    src/core/ModuleWorkerClient.cpp src/core/ModuleWorkerClient.h
    src/core/ModulePageHost.cpp src/core/ModulePageHost.h
    src/core/AppNetworkBroker.cpp src/core/AppNetworkBroker.h
    src/core/AppNetworkApi.cpp src/core/AppNetworkApi.h
    src/core/FileApiBroker.cpp src/core/FileApiBroker.h
    src/core/FileApi.cpp src/core/FileApi.h
    src/files/FileProtocol.h
    src/core/LaneGate.cpp src/core/LaneGate.h
    src/core/PowerStatus.cpp src/core/PowerStatus.h
    src/core/SecurityService.cpp src/core/SecurityService.h
    src/core/ModuleDataApi.cpp src/core/ModuleDataApi.h
    src/core/FetchBudget.cpp src/core/FetchBudget.h
    src/net/NetPolicy.cpp src/net/NetPolicy.h src/net/NetChannels.h
    src/net/PublicNetwork.cpp src/net/PublicNetwork.h
    src/net/NetworkPolicy.cpp src/net/NetworkPolicy.h
    src/net/NetworkPolicyController.cpp src/net/NetworkPolicyController.h
    src/app/OnboardingController.cpp src/app/OnboardingController.h)
target_include_directories(terminal_core PUBLIC src src/modules/api)
# build-info.h 由 build_info 目标生成（build 日期），只给需要它的源码用。
target_include_directories(terminal_core PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
add_dependencies(terminal_core build_info)
target_link_libraries(terminal_core PUBLIC terminal_gate terminal_transports terminal_security terminal_routing Qt6::Core Qt6::Network Qt6::StateMachine Qt6::Qml Qt6::Quick)
target_compile_definitions(terminal_core PRIVATE PI_PACKAGE_TOOL="${CMAKE_INSTALL_PREFIX}/libexec/orange-pi-terminal/package_tool.py")
target_compile_definitions(terminal_core PRIVATE PI_MODULE_INSTALL_HELPER="${CMAKE_INSTALL_PREFIX}/libexec/orange-pi-terminal/module_install_helper.py")
target_compile_options(terminal_core PRIVATE -Wall -Wextra -Wpedantic)
# 界面接点需要在没有 mbedtls 的构建里也能编译：身份那一块按此宏降级为
# "unavailable"，而不是让整个 terminal_core 依赖 mbedtls。
if(TERMINAL_SECURITY_HAVE_MBEDTLS)
    target_compile_definitions(terminal_core PRIVATE TERMINAL_HAVE_MBEDTLS=1)
endif()
# 安全状态页的独立预览程序（开发工具，不随产品安装）。
# 只加载 qml/SecurityStatusPage.qml，不碰 Main.qml，因此与 Z 的 T-09 零重叠；
# 也不链接 terminal_ui，所以不依赖 VLC SDK。
# 本地出站代理（独立进程）：四条网络栈按通道端口接进来，见 docs/networking.md。
add_executable(network_proxy src/net/proxy_main.cpp src/net/ProxyServer.cpp src/net/ProxyServer.h
    src/net/PublicNetwork.cpp src/net/PublicNetwork.h
    src/net/NetworkPolicy.cpp src/net/NetworkPolicy.h)
target_include_directories(network_proxy PRIVATE src)
target_link_libraries(network_proxy PRIVATE Qt6::Core Qt6::Network)
target_compile_options(network_proxy PRIVATE -Wall -Wextra -Wpedantic)

# 每用户文件 daemon：唯一能访问家目录的组件；模块只能经宿主 API 使用。
add_executable(orange-pi-file-daemon src/files/file_daemon_main.cpp
    src/files/FileDaemonServer.cpp src/files/FileDaemonServer.h
    src/files/FileProtocol.h)
target_include_directories(orange-pi-file-daemon PRIVATE src)
target_link_libraries(orange-pi-file-daemon PRIVATE Qt6::Core Qt6::Network)
target_compile_options(orange-pi-file-daemon PRIVATE -Wall -Wextra -Wpedantic)

# root 策略写入器：由 Polkit/pkexec 调用，只接受 stdin 上的策略 JSON。
set(NET_POLICY_HELPER_INSTALL_PATH
    "${CMAKE_INSTALL_FULL_LIBEXECDIR}/orange-pi-terminal/net-policy-helper")
configure_file(packaging/com.orangepi.terminal.network-policy.policy.in
    "${CMAKE_CURRENT_BINARY_DIR}/com.orangepi.terminal.network-policy.policy" @ONLY)
target_compile_definitions(terminal_core PRIVATE
    PI_NET_POLICY_HELPER="${NET_POLICY_HELPER_INSTALL_PATH}")
add_executable(net_policy_helper src/net/net_policy_helper.cpp src/net/NetworkPolicy.cpp
    src/net/NetworkPolicy.h)
target_include_directories(net_policy_helper PRIVATE src)
target_link_libraries(net_policy_helper PRIVATE Qt6::Core)
set_target_properties(net_policy_helper PROPERTIES OUTPUT_NAME net-policy-helper)
target_compile_options(net_policy_helper PRIVATE -Wall -Wextra -Wpedantic)

add_executable(security_preview tools/security_preview/main.cpp)
target_link_libraries(security_preview PRIVATE terminal_core Qt6::Quick)
target_compile_definitions(security_preview PRIVATE
    PREVIEW_PAGE="${CMAKE_CURRENT_SOURCE_DIR}/qml/SecurityStatusPage.qml")

add_library(terminal_music SHARED
    src/ui/MusicPlayback.cpp src/ui/MusicPlayback.h
    src/ui/MusicService.cpp src/ui/MusicService.h)
target_include_directories(terminal_music PUBLIC src)
target_link_libraries(terminal_music PUBLIC terminal_gate Qt6::Core Qt6::Network)
target_compile_definitions(terminal_music PRIVATE TERMINAL_MUSIC_API_SOURCE="${CMAKE_CURRENT_SOURCE_DIR}/music_api")

add_library(terminal_system SHARED
    src/ui/SystemTools.cpp src/ui/SystemTools.h
    src/ui/SystemVolume.cpp src/ui/SystemVolume.h
    src/ui/RemovableStorage.cpp src/ui/RemovableStorage.h
    src/ui/DesktopShell.cpp src/ui/DesktopShell.h
    src/ui/ViperBrowserController.cpp src/ui/ViperBrowserController.h
    src/ui/TimeSyncClient.cpp src/ui/TimeSyncClient.h)
target_include_directories(terminal_system PUBLIC src)
target_include_directories(terminal_system PRIVATE
    ../third_party/Viper-Browser/src/core
    ../third_party/Viper-Browser/src
    ../third_party/Viper-Browser/src/core
    ../third_party/Viper-Browser/src/core/adblock
    ../third_party/Viper-Browser/src/core/app
    ../third_party/Viper-Browser/src/core/autofill
    ../third_party/Viper-Browser/src/core/bookmarks
    ../third_party/Viper-Browser/src/core/cache
    ../third_party/Viper-Browser/src/core/cookies
    ../third_party/Viper-Browser/src/core/credentials
    ../third_party/Viper-Browser/src/core/database
    ../third_party/Viper-Browser/src/core/database/sqlite
    ../third_party/Viper-Browser/src/core/downloads
    ../third_party/Viper-Browser/src/core/extensions
    ../third_party/Viper-Browser/src/core/highlighters
    ../third_party/Viper-Browser/src/core/history
    ../third_party/Viper-Browser/src/core/icons
    ../third_party/Viper-Browser/src/core/ipc
    ../third_party/Viper-Browser/src/core/network
    ../third_party/Viper-Browser/src/core/search
    ../third_party/Viper-Browser/src/core/session
    ../third_party/Viper-Browser/src/core/settings
    ../third_party/Viper-Browser/src/core/text_finder
    ../third_party/Viper-Browser/src/core/threading
    ../third_party/Viper-Browser/src/core/url_suggestion
    ../third_party/Viper-Browser/src/core/user_agents
    ../third_party/Viper-Browser/src/core/user_scripts
    ../third_party/Viper-Browser/src/core/utility
    ../third_party/Viper-Browser/src/core/web
    ../third_party/Viper-Browser/src/ui
    ../third_party/Viper-Browser/src/ui/adblock
    ../third_party/Viper-Browser/src/ui/autofill
    ../third_party/Viper-Browser/src/ui/bookmarks
    ../third_party/Viper-Browser/src/ui/cookies
    ../third_party/Viper-Browser/src/ui/downloads)
target_link_libraries(terminal_system PUBLIC terminal_music Qt6::Gui Qt6::Bluetooth Qt6::TextToSpeech Qt6::WebEngineQuick
    PRIVATE Qt6::Widgets Qt6::WebEngineWidgets Qt6::Multimedia viper-core viper-ui)
# Viper-Browser 静态链接了一份完整 SQLite（libviper-sqlite3.a），它的 sqlite3_* 是
# 强符号；主程序另外链接了 libsqlcipher.so（也有同名强符号）。两者同时出现在动态
# 符号表里时，动态链接器只会绑定其中一个：sqlite3_open 走 A 副本、sqlcipher_activate
# 走 B 副本，两套全局状态互不知晓，表现为 sqlite3_initialize 自锁、登录后窗口无响应。
# 把这个静态库的符号本地化，Viper 内部仍用自己的副本，外部统一用 libsqlcipher。
target_link_options(terminal_system PRIVATE "LINKER:--exclude-libs,libviper-sqlite3.a")
# 语音引擎数据目录：构建树内直接可用；安装后优先读 share/orange-pi-terminal。
target_compile_definitions(terminal_system PRIVATE TERMINAL_TTS_ASSET_DIR="${CMAKE_CURRENT_SOURCE_DIR}/assets")

qt_add_library(terminal_ui SHARED
    src/ui/TerminalUi.cpp src/ui/TerminalUi.h
    src/ui/BlurItem.cpp src/ui/BlurItem.h src/ui/TextFormatter.h
    src/ui/PetSpriteItem.cpp src/ui/PetSpriteItem.h
    src/ui/PetLibrary.cpp src/ui/PetLibrary.h
    src/ui/GstVideoItem.cpp src/ui/GstVideoItem.h)
target_compile_definitions(terminal_ui PRIVATE ARKPETS_CONVERTER_SOURCE="${CMAKE_CURRENT_SOURCE_DIR}/tools/arkpets")
target_include_directories(terminal_ui PUBLIC src)
target_link_libraries(terminal_ui PUBLIC Qt6::Quick Qt6::Qml PRIVATE terminal_vlc Qt6::QuickControls2 Qt6::OpenGL)

# ── 中文语音引擎：vendored flite + 音节单元拼接 ──
# 默认直接构建 third_party/flite（免安装、无外部依赖）；
# 交叉编译或想复用系统 flite 时，用 -DFLITE_ROOT=<已构建的 flite 源码树> 覆盖。
set(FLITE_ROOT "" CACHE PATH "可选：已构建的 flite 源码树（含 include/ 与 build/<arch>/lib/libflite.a）")
if(FLITE_ROOT)
    set(FLITE_INCLUDE_DIR "${FLITE_ROOT}/include")
    set(FLITE_LIBRARY "${FLITE_ROOT}/build/${CMAKE_LIBRARY_ARCHITECTURE}/lib/libflite.a")
    set(FLITE_LEX_LIBRARY "${FLITE_ROOT}/build/${CMAKE_LIBRARY_ARCHITECTURE}/lib/libflite_cmulex.a")
    set(FLITE_EN_LIBRARY "${FLITE_ROOT}/build/${CMAKE_LIBRARY_ARCHITECTURE}/lib/libflite_usenglish.a")
    if(NOT EXISTS "${FLITE_LIBRARY}")
        message(FATAL_ERROR "找不到 ${FLITE_LIBRARY}，请先在 flite 源码树里 make -C src")
    endif()
else()
    set(FLITE_BUILD_DIR "${CMAKE_BINARY_DIR}/third_party-flite")
    set(FLITE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/flite")
    set(FLITE_INCLUDE_DIR "${FLITE_BUILD_DIR}/include")
    set(FLITE_LIBRARY "${FLITE_BUILD_DIR}/build/${CMAKE_LIBRARY_ARCHITECTURE}/lib/libflite.a")
    set(FLITE_LEX_LIBRARY "${FLITE_BUILD_DIR}/build/${CMAKE_LIBRARY_ARCHITECTURE}/lib/libflite_cmulex.a")
    set(FLITE_EN_LIBRARY "${FLITE_BUILD_DIR}/build/${CMAKE_LIBRARY_ARCHITECTURE}/lib/libflite_usenglish.a")
    # 交叉编译时把目标 triplet 传给 flite 的 configure，避免它按宿主编译器猜 host。
    set(FLITE_HOST_ARG "")
    if(CMAKE_CROSSCOMPILING)
        get_filename_component(_flite_cc_name "${CMAKE_C_COMPILER}" NAME_WE)
        string(REGEX REPLACE "-gcc.*$" "" _flite_triplet "${_flite_cc_name}")
        set(FLITE_HOST_ARG "--host=${_flite_triplet}")
    endif()
    add_custom_command(
        OUTPUT "${FLITE_LIBRARY}"
        COMMAND ${CMAKE_COMMAND} -E rm -rf "${FLITE_BUILD_DIR}"
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${FLITE_SOURCE_DIR}" "${FLITE_BUILD_DIR}"
        COMMAND ${CMAKE_COMMAND} -E chdir "${FLITE_BUILD_DIR}"
                ${CMAKE_COMMAND} -E env "CC=${CMAKE_C_COMPILER}" "CXX=${CMAKE_CXX_COMPILER}"
                ./configure -q --with-audio=none ${FLITE_HOST_ARG}
        COMMAND ${CMAKE_COMMAND} -E chdir "${FLITE_BUILD_DIR}" make -C src -j
        COMMAND ${CMAKE_COMMAND} -E chdir "${FLITE_BUILD_DIR}" make -C lang/cmulex -j
        COMMAND ${CMAKE_COMMAND} -E chdir "${FLITE_BUILD_DIR}" make -C lang/usenglish -j
        BYPRODUCTS "${FLITE_LEX_LIBRARY}" "${FLITE_EN_LIBRARY}"
        DEPENDS "${FLITE_SOURCE_DIR}/configure"
        COMMENT "构建 vendored flite（只构建 libflite，跳过音色与文档）"
        VERBATIM)
    add_custom_target(flite_vendored DEPENDS "${FLITE_LIBRARY}")
endif()
add_executable(terminal_flite_zh tts/flite/zh_engine.c tts/flite/zh_main.c)
target_include_directories(terminal_flite_zh PRIVATE "${FLITE_INCLUDE_DIR}")
# 英文前端（cmulex + usenglish）只在有 slt flitevox 时用得到，但一起链进来最简单
target_link_libraries(terminal_flite_zh PRIVATE "${FLITE_EN_LIBRARY}" "${FLITE_LEX_LIBRARY}" "${FLITE_LIBRARY}" m pthread)
if(TARGET flite_vendored)
    add_dependencies(terminal_flite_zh flite_vendored)
endif()
install(TARGETS terminal_flite_zh RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR} COMPONENT TerminalRuntime)
install(DIRECTORY assets/voices DESTINATION share/orange-pi-terminal COMPONENT TerminalRuntime)
install(FILES assets/tts/zh_dict.bin assets/tts/cmu_us_slt.flitevox DESTINATION share/orange-pi-terminal/tts COMPONENT TerminalRuntime)
install(FILES tts/flite/LICENSE-flite.txt DESTINATION share/orange-pi-terminal/licenses/flite COMPONENT TerminalRuntime)
install(FILES ../third_party/flite/COPYING ../third_party/flite/ACKNOWLEDGEMENTS
        DESTINATION share/orange-pi-terminal/licenses/flite/upstream COMPONENT TerminalRuntime)

# ── 自研 GStreamer 播放内核 ──
# 开发头文件随仓库提供（third_party/gst/<arch>，由 tools/fetch_gst_headers.sh 生成），
# 不需要在新机器上安装 *-dev 包；运行时用系统已有的 GStreamer（Qt Multimedia 本来就依赖它）。
if(CMAKE_CROSSCOMPILING)
    set(GST_ROOT "${CMAKE_SYSROOT}/usr")
    set(GST_GLIB_ARCH "${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu/glib-2.0/include")
    target_link_directories(terminal_ui PRIVATE "${GST_ROOT}/lib/${CMAKE_LIBRARY_ARCHITECTURE}")
else()
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
        set(GST_ARCH arm64)
    else()
        set(GST_ARCH amd64)
    endif()
    set(GST_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/gst/${GST_ARCH}")
    set(GST_GLIB_ARCH "${GST_ROOT}/include/glib-arch")
    if(NOT EXISTS "${GST_ROOT}/include/glib-arch/glibconfig.h")
        message(FATAL_ERROR
            "缺少 ${GST_ROOT}。请执行 `${CMAKE_CURRENT_SOURCE_DIR}/../tools/fetch_gst_headers.sh` 生成（免 root）。")
    endif()
    target_link_directories(terminal_ui PRIVATE "${GST_ROOT}/lib")
endif()
target_include_directories(terminal_ui PUBLIC
    "${GST_ROOT}/include/gstreamer-1.0"
    "${GST_ROOT}/include/glib-2.0"
    "${GST_GLIB_ARCH}")
target_link_libraries(terminal_ui PRIVATE gstreamer-1.0 gstapp-1.0 gstvideo-1.0 gobject-2.0 glib-2.0)

# 最小视频探针（开发/性能测试用，不参与安装）
# 模块 worker 入口（T-11）：独立进程加载模块 .so，由 systemd unit 约束沙箱。
qt_add_executable(module_worker src/core/module_worker_main.cpp src/core/WorkerIpc.cpp)
target_include_directories(module_worker PRIVATE src)
target_link_libraries(module_worker PRIVATE Qt6::Core Qt6::Network)
target_compile_options(module_worker PRIVATE -Wall -Wextra -Wpedantic)

qt_add_executable(kdf_bench tools/kdf_bench.cpp)
target_link_libraries(kdf_bench PRIVATE terminal_security Qt6::Core)

qt_add_executable(tv_probe tools/tv_probe.cpp)
target_link_libraries(tv_probe PRIVATE terminal_ui Qt6::Quick)


qt_add_executable(orange_pi_terminal
    src/main.cpp src/app/TerminalApplication.cpp src/app/TerminalApplication.h
    src/app/TerminalOptions.cpp src/app/TerminalOptions.h
    src/app/TerminalRuntime.cpp src/app/TerminalRuntime.h
    src/app/DiagnosticRunner.cpp src/app/DiagnosticRunner.h
    src/app/AdminInitializer.cpp src/app/AdminInitializer.h)
target_include_directories(orange_pi_terminal PRIVATE ../third_party/Viper-Browser/src/core/network)
target_link_libraries(orange_pi_terminal PRIVATE terminal_security terminal_core)
# 登录页右上角显示版本号；与 CMake project(VERSION) 保持单一来源。
target_compile_definitions(orange_pi_terminal PRIVATE ORANGE_PI_VERSION="${PROJECT_VERSION}")

set(TERMINAL_LIBRARY_DIR "${CMAKE_INSTALL_LIBDIR}/orange-pi-terminal")
foreach(module IN ITEMS terminal_music terminal_system terminal_ui)
    set_target_properties(${module} PROPERTIES
        VERSION ${PROJECT_VERSION} SOVERSION 1
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/lib/orange-pi-terminal"
        BUILD_RPATH_USE_ORIGIN TRUE INSTALL_RPATH "$ORIGIN")
endforeach()
file(RELATIVE_PATH TERMINAL_LIBRARY_FROM_BIN "${CMAKE_INSTALL_FULL_BINDIR}" "${CMAKE_INSTALL_FULL_LIBDIR}/orange-pi-terminal")
set_target_properties(orange_pi_terminal PROPERTIES
    BUILD_RPATH_USE_ORIGIN TRUE INSTALL_RPATH "$ORIGIN/${TERMINAL_LIBRARY_FROM_BIN}")
set(UI_QML_FILES qml/Main.qml qml/Theme.qml qml/I18n.qml qml/GlassSurface.qml qml/CarText.qml qml/CarButton.qml qml/CarField.qml qml/MaterialIcon.qml qml/IconButton.qml qml/AppIcon.qml qml/PaintToolButton.qml qml/AppLauncher.qml qml/ApplicationDrawer.qml qml/StatusDock.qml qml/SettingsGroup.qml qml/FloatingKeyboard.qml qml/MusicPlayer.qml qml/VideoPlayer.qml)
list(APPEND UI_QML_FILES qml/RightSlidePage.qml)
list(APPEND UI_QML_FILES qml/ReadOnlyTextView.qml)
list(APPEND UI_QML_FILES qml/ConnectionSettingsPage.qml qml/SecurityStatusSection.qml)
list(APPEND UI_QML_FILES qml/AboutDevicePage.qml qml/AboutInfoRow.qml qml/CreditsPage.qml)
list(APPEND UI_QML_FILES qml/NetworkPermissionsPage.qml)
list(APPEND UI_QML_FILES qml/DeveloperPanel.qml)
list(APPEND UI_QML_FILES qml/TestModePanel.qml)
list(APPEND UI_QML_FILES qml/MusicModeButton.qml)
list(APPEND UI_QML_FILES qml/BrowserJoystick.qml)
set_source_files_properties(qml/BrowserScroll.js PROPERTIES QT_RESOURCE_ALIAS BrowserScroll.js)
list(APPEND UI_QML_FILES qml/BrowserWheel.qml qml/DirectionWheel.qml)
set_source_files_properties(qml/ContextScroll.js PROPERTIES QT_RESOURCE_ALIAS ContextScroll.js)
set_source_files_properties(qml/WheelStrings.js PROPERTIES QT_RESOURCE_ALIAS WheelStrings.js)
list(APPEND UI_QML_FILES qml/MusicText.qml)
list(APPEND UI_QML_FILES qml/PictureViewer.qml qml/FileThumbnail.qml)
list(APPEND UI_QML_FILES qml/QuickToggle.qml qml/EditorToolbar.qml)
list(APPEND UI_QML_FILES qml/QuickPanelTile.qml)
list(APPEND UI_QML_FILES qml/KeyboardKey.qml)
list(APPEND UI_QML_FILES qml/PinPad.qml qml/Avatar.qml qml/UserPicker.qml qml/LoginPage.qml qml/LockScreen.qml qml/SessionGate.qml)
# 删账户等待层（删完到下一个界面之间的至少 4 秒）。
list(APPEND UI_QML_FILES qml/AdminDeleteWait.qml)
# 数据页的目标 U 盘选择器（用户只看得到盘名，不展示地址与后缀）。
list(APPEND UI_QML_FILES qml/UsbDevicePicker.qml)
# 恢复码导出到 U 盘（开机向导 / 其他用户 / 锁屏三处复用）。
list(APPEND UI_QML_FILES qml/RecoveryExport.qml)
# 锁屏上的创建新用户（验 PIN -> 填表 -> 恢复码）。
list(APPEND UI_QML_FILES qml/LockCreateUser.qml)
# 「我已抄写」的 5 秒确认（三处恢复码共用）。
list(APPEND UI_QML_FILES qml/RecoveryAckConfirm.qml)
# 首次开机向导（OOBE）：七个子目录文件按 basename 平铺到模块根，
# 这样 OnboardingWizard.qml 里的 Loader 可以直接用 "WelcomeStep.qml" 之类的相对路径。
list(APPEND UI_QML_FILES
    qml/onboarding/OnboardingWizard.qml
    qml/onboarding/ProgressHeader.qml
    qml/onboarding/WelcomeStep.qml
    qml/onboarding/AdminStep.qml
    qml/onboarding/RecoveryStep.qml
    qml/onboarding/NetworkStep.qml
    qml/onboarding/DoneStep.qml)
list(APPEND UI_QML_FILES qml/AdminPairingPage.qml qml/TaskFinishDialog.qml)
# 注意：啸天围界与血压读数的页面属于**模块包**（module-devkit/examples/*/qml），
# 不注册进宿主资源，由 ModulePageHost 在独立引擎里从模块包加载。
list(APPEND UI_QML_FILES qml/BlurCache.qml)
list(APPEND UI_QML_FILES qml/CachedBlur.qml)
list(APPEND UI_QML_FILES qml/StartupSplash.qml)
list(APPEND UI_QML_FILES qml/TimeTools.qml)
list(APPEND UI_QML_FILES qml/AlarmEngine.qml)
list(APPEND UI_QML_FILES qml/TimePane.qml)
list(APPEND UI_QML_FILES qml/TimeSync.qml)
list(APPEND UI_QML_FILES qml/TimeSyncSettings.qml)
list(APPEND UI_QML_FILES qml/LockSettings.qml)
list(APPEND UI_QML_FILES qml/NetworkPermissions.qml)
list(APPEND UI_QML_FILES qml/VoiceSettings.qml)
list(APPEND UI_QML_FILES qml/WeatherTools.qml)
list(APPEND UI_QML_FILES qml/WeatherEngine.qml)
list(APPEND UI_QML_FILES qml/WeatherSettings.qml)
list(APPEND UI_QML_FILES qml/UserSecurityPage.qml)
list(APPEND UI_QML_FILES qml/UserSecurityView.qml)
# 用户与权限主页：五张分类卡片（子目录文件按 basename 平铺到模块根）。
list(APPEND UI_QML_FILES qml/user/UserSecurityHome.qml)
list(APPEND UI_QML_FILES qml/ModuleAuthPanel.qml)
list(APPEND UI_QML_FILES qml/Speech.qml)
set_source_files_properties(qml/TimeMath.js PROPERTIES QT_RESOURCE_ALIAS TimeMath.js)
set_source_files_properties(qml/WeatherMath.js PROPERTIES QT_RESOURCE_ALIAS WeatherMath.js)
list(APPEND UI_QML_FILES qml/DesktopPet.qml)
list(APPEND UI_QML_FILES qml/PetManager.qml)
list(APPEND UI_QML_FILES qml/TvPlayer.qml)
list(APPEND UI_QML_FILES qml/SecurityStatusPage.qml)
foreach(qml_file IN LISTS UI_QML_FILES)
    get_filename_component(qml_name "${qml_file}" NAME)
    set_source_files_properties("${qml_file}" PROPERTIES QT_RESOURCE_ALIAS "${qml_name}")
endforeach()
set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
set_source_files_properties(qml/I18n.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
set_source_files_properties(qml/Speech.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
qt_add_qml_module(terminal_ui URI OrangePiTerminal NO_PLUGIN
    OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/OrangePiTerminal"
    RESOURCE_PREFIX /qt/qml VERSION 1.0 QML_FILES ${UI_QML_FILES}
        qml/BrowserScroll.js qml/ContextScroll.js qml/WheelStrings.js qml/TimeMath.js qml/WeatherMath.js)
file(GLOB MATERIAL_ICONS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/qml/icons/material/dark/*.svg" "${CMAKE_CURRENT_SOURCE_DIR}/qml/icons/material/light/*.svg")
set_source_files_properties(assets/fonts/GoogleSans.ttf PROPERTIES QT_RESOURCE_ALIAS GoogleSans.ttf)
set_source_files_properties(assets/fonts/OFL.txt PROPERTIES QT_RESOURCE_ALIAS OFL.txt)
set_source_files_properties(assets/fonts/TRADEMARKS.md PROPERTIES QT_RESOURCE_ALIAS TRADEMARKS.md)
qt_add_resources(terminal_ui icons PREFIX /icons BASE qml/icons FILES qml/icons/extension.svg qml/icons/eraser.svg qml/icons/module-default.svg qml/icons/browser-new-tab.svg ${MATERIAL_ICONS})
qt_add_resources(terminal_ui google_sans PREFIX /fonts FILES assets/fonts/GoogleSans.ttf assets/fonts/OFL.txt assets/fonts/TRADEMARKS.md)
qt_add_resources(terminal_system pinyin_dictionary PREFIX /pinyin BASE assets/pinyin FILES assets/pinyin/pinyin_simp.dict.yaml assets/pinyin/phrases.tsv assets/pinyin/LICENSE assets/pinyin/AUTHORS assets/pinyin/PYPINYIN-LICENSE assets/pinyin/SOURCES.md)
qt_add_resources(terminal_system pinyin_frequency PREFIX /pinyin BASE assets/pinyin FILES assets/pinyin/jieba-dict.txt assets/pinyin/JIEBA-LICENSE)
set_source_files_properties(assets/orange_pi_terminal.svg PROPERTIES QT_RESOURCE_ALIAS orange_pi_terminal.svg)
qt_add_resources(terminal_ui app_icon PREFIX /icons FILES assets/orange_pi_terminal.svg)
qt_add_resources(terminal_ui tv_channels PREFIX /tv BASE assets/tv FILES assets/tv/china.json assets/tv/SOURCE.md)
qt_add_resources(terminal_ui ringtones PREFIX /ringtones BASE assets/ringtones
    FILES assets/ringtones/default-ringtone.mp3)
qt_add_resources(terminal_ui arkpets_sprites PREFIX /arkpets BASE assets/arkpets
    FILES assets/arkpets/amiya/idle.png assets/arkpets/amiya/walk.png
          assets/arkpets/amiya/interact.png assets/arkpets/amiya/sit.png
          assets/arkpets/amiya/sleep.png assets/arkpets/amiya/animations.json)
qt_add_shaders(terminal_ui cached_blur_shader PREFIX /shaders BASE qml/shaders
    GLSL "100 es,120,150" FILES qml/shaders/cached-blur.frag)
target_link_libraries(orange_pi_terminal PRIVATE terminal_core terminal_system terminal_ui viper-core Qt6::Widgets Qt6::QuickControls2 Qt6::QuickTemplates2Private Qt6::OpenGL Qt6::WebEngineQuick)
# 语音是运行期依赖：构建主程序时一并产出 flite helper，避免"先起应用、后建 helper"
# 时 fliteReady 在进程内被缓存成不可用。
add_dependencies(orange_pi_terminal terminal_flite_zh)
if(TERMINAL_REPAIR_AUDIT)
    find_package(Qt6 6.4 REQUIRED COMPONENTS Test)
    target_link_libraries(orange_pi_terminal PRIVATE Qt6::Test)
    target_compile_definitions(orange_pi_terminal PRIVATE TERMINAL_REPAIR_AUDIT)
endif()
add_subdirectory(modules/example)
add_subdirectory(modules/test_devices)
if(BUILD_TESTING)
    target_sources(orange_pi_terminal PRIVATE tests/GuiAudit.cpp)
    add_executable(arkpets_preview tests/arkpets_preview.cpp)
    target_link_libraries(arkpets_preview PRIVATE terminal_ui Qt6::QuickControls2)
    target_compile_definitions(arkpets_preview PRIVATE ARKPETS_PREVIEW_QML="${CMAKE_CURRENT_SOURCE_DIR}/tests/arkpets_preview.qml")
    add_executable(desktop_pet_test tests/desktop_pet_test.cpp)
    target_link_libraries(desktop_pet_test PRIVATE terminal_ui Qt6::Test Qt6::QuickControls2 Qt6::Widgets)
    target_compile_definitions(desktop_pet_test PRIVATE ARKPETS_PREVIEW_QML="${CMAKE_CURRENT_SOURCE_DIR}/tests/arkpets_preview.qml")
    add_test(NAME arkpets_local_interaction COMMAND desktop_pet_test)
    add_executable(pet_manager_test tests/pet_manager_test.cpp)
    target_link_libraries(pet_manager_test PRIVATE terminal_ui terminal_system Qt6::Test Qt6::QuickControls2 Qt6::Widgets)
    target_compile_definitions(pet_manager_test PRIVATE ARKPETS_PREVIEW_QML="${CMAKE_CURRENT_SOURCE_DIR}/tests/arkpets_preview.qml")
    add_test(NAME arkpets_manager_material_list_detail COMMAND pet_manager_test)
    set_tests_properties(arkpets_manager_material_list_detail PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software" TIMEOUT 45)
    set_tests_properties(arkpets_local_interaction PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software" TIMEOUT 30)
    add_executable(text_formatter_test tests/text_formatter_test.cpp)
    target_include_directories(text_formatter_test PRIVATE src)
    target_link_libraries(text_formatter_test PRIVATE terminal_ui Qt6::Test)
    add_test(NAME text_editor_format_roundtrip COMMAND text_formatter_test)
    set_tests_properties(text_editor_format_roundtrip PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software")
    target_include_directories(orange_pi_terminal PRIVATE tests)
    target_link_libraries(orange_pi_terminal PRIVATE Qt6::Test)
    target_compile_definitions(orange_pi_terminal PRIVATE TERMINAL_GUI_AUDIT)
    add_executable(pbr_aead_test tests/pbr_aead_test.cpp)
    target_link_libraries(pbr_aead_test PRIVATE terminal_protocol Qt6::Test)
    target_compile_definitions(pbr_aead_test PRIVATE
        VECTORS_PATH="${CMAKE_CURRENT_SOURCE_DIR}/../docs/pbr-secure-v1/vectors.json")
    add_test(NAME pbr_aead_envelope COMMAND pbr_aead_test)
    add_executable(pbr_session_test tests/pbr_session_test.cpp)
    target_link_libraries(pbr_session_test PRIVATE terminal_protocol Qt6::Test)
    add_test(NAME pbr_replay_and_dedup COMMAND pbr_session_test)
    add_executable(pbr_handshake_test tests/pbr_handshake_test.cpp)
    target_link_libraries(pbr_handshake_test PRIVATE terminal_protocol Qt6::Test)
    target_compile_definitions(pbr_handshake_test PRIVATE
        VECTORS_PATH="${CMAKE_CURRENT_SOURCE_DIR}/../docs/pbr-secure-v1/vectors.json")
    add_test(NAME pbr_handshake_derivation COMMAND pbr_handshake_test)
    add_executable(protocol_test tests/protocol_test.cpp)
    target_link_libraries(protocol_test PRIVATE terminal_protocol)
    add_test(NAME pibridge_protocol COMMAND protocol_test)
    add_executable(slot_router_test tests/slot_router_test.cpp)
    target_link_libraries(slot_router_test PRIVATE terminal_routing)
    add_test(NAME pbr_slot_router COMMAND slot_router_test)
    add_executable(security_status_test tests/security_status_test.cpp)
    target_link_libraries(security_status_test PRIVATE terminal_core Qt6::Test)
    # terminal_core 把该宏设为 PRIVATE，测试要按同一条件编译身份相关用例，
    # 否则会出现"库里有身份、测试却跳过"的假阴性。
    if(TERMINAL_SECURITY_HAVE_MBEDTLS)
        target_compile_definitions(security_status_test PRIVATE TERMINAL_HAVE_MBEDTLS=1)
    endif()
    add_test(NAME pbr_security_status COMMAND security_status_test)
    add_executable(trust_store_test tests/trust_store_test.cpp)
    target_link_libraries(trust_store_test PRIVATE terminal_security)
    add_test(NAME pbr_trust_store COMMAND trust_store_test)
    # UID 索引：KAT 用测试密钥提供者，独立于产品的默认失败关闭实现。
    add_executable(uid_index_test tests/uid_index_test.cpp
        src/protocol/uid_index.cpp tests/support/uid_index_key_fixed.cpp)
    target_include_directories(uid_index_test PRIVATE src)
    target_link_libraries(uid_index_test PRIVATE Qt6::Core)
    add_test(NAME pbr_uid_index COMMAND uid_index_test)
    # 产品当前只有 Z 的真实实现（uid_index_key.cpp）。这条用例改为验证
    # deriveUidIndex() 在密钥缺失时失败关闭：用测试替身控制"有/无密钥"两态。
    add_executable(uid_index_default_key_test tests/uid_index_default_key_test.cpp
        src/protocol/uid_index.cpp tests/support/uid_index_key_fixed.cpp)
    target_include_directories(uid_index_default_key_test PRIVATE src)
    target_link_libraries(uid_index_default_key_test PRIVATE Qt6::Core)
    add_test(NAME pbr_uid_index_fail_closed COMMAND uid_index_default_key_test)
    if(TERMINAL_SECURITY_HAVE_MBEDTLS)
        add_executable(host_identity_test tests/host_identity_test.cpp)
        target_link_libraries(host_identity_test PRIVATE terminal_security)
        add_test(NAME pbr_host_identity COMMAND host_identity_test)
    endif()
    add_executable(uid_index_key_test tests/uid_index_key_test.cpp)
    target_link_libraries(uid_index_key_test PRIVATE terminal_security Qt6::Test)
    add_test(NAME uid_index_key_lifecycle COMMAND uid_index_key_test)
    add_executable(auth_service_test tests/auth_service_test.cpp)
    target_link_libraries(auth_service_test PRIVATE terminal_security Qt6::Test)
    add_test(NAME user_pin_session COMMAND auth_service_test)
    add_executable(user_database_test tests/user_database_test.cpp)
    target_link_libraries(user_database_test PRIVATE terminal_security Qt6::Test)
    add_test(NAME sqlcipher_user_isolation COMMAND user_database_test)
    add_executable(login_qml_test tests/login_qml_test.cpp)
    target_link_libraries(login_qml_test PRIVATE Qt6::Test Qt6::Quick Qt6::Qml Qt6::QuickControls2)
    target_compile_definitions(login_qml_test PRIVATE
        TERMINAL_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/qml")
    # Theme/I18n 是 pragma Singleton，必须通过 qml module 注册，否则 I18n.t 是 undefined，
    # 组件照样"实例化成功"但每个绑定都报错 —— 那种测试是假绿。
    set(login_test_qml
        qml/Theme.qml qml/I18n.qml qml/CarText.qml qml/CarButton.qml qml/CarField.qml
        qml/MaterialIcon.qml qml/IconButton.qml qml/PinPad.qml qml/Avatar.qml
        qml/UserPicker.qml qml/LoginPage.qml qml/LockScreen.qml
        # 锁屏上的建号入口连带这几个组件，测试模块也要有一份，否则是 unknown type。
        qml/LockCreateUser.qml qml/RecoveryExport.qml qml/UsbDevicePicker.qml
        qml/RecoveryAckConfirm.qml)
    set_source_files_properties(qml/Theme.qml qml/I18n.qml
        PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
    foreach(file IN LISTS login_test_qml)
        get_filename_component(alias "${file}" NAME)
        set_source_files_properties("${file}" PROPERTIES QT_RESOURCE_ALIAS "${alias}")
    endforeach()
    # 独立 URI，避免与 terminal_ui 共用输出目录（Qt 不允许两个模块同目录）。
    qt_add_qml_module(login_qml_test URI OrangePiTerminal.LoginTest VERSION 1.0
        RESOURCE_PREFIX /qt/qml OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/LoginTestQml"
        QML_FILES ${login_test_qml})
    add_test(NAME login_lock_user_pages COMMAND login_qml_test)
    set_tests_properties(login_lock_user_pages PROPERTIES LABELS "interface"
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software" TIMEOUT 60)
    add_executable(module_worker_ipc_test tests/module_worker_ipc_test.cpp)
    target_include_directories(module_worker_ipc_test PRIVATE src)
    target_compile_definitions(module_worker_ipc_test PRIVATE
        EXAMPLES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/modules")
    target_link_libraries(module_worker_ipc_test PRIVATE terminal_core Qt6::Test)
    add_dependencies(module_worker_ipc_test module_worker example_module)
    add_test(NAME worker_socket_ipc COMMAND module_worker_ipc_test)
    add_executable(module_worker_async_test tests/module_worker_async_test.cpp)
    target_include_directories(module_worker_async_test PRIVATE src)
    target_link_libraries(module_worker_async_test PRIVATE terminal_core Qt6::Test)
    add_dependencies(module_worker_async_test module_worker example_module)
    add_test(NAME module_worker_async COMMAND module_worker_async_test)
    add_executable(session_gate_test tests/session_gate_test.cpp)
    target_link_libraries(session_gate_test PRIVATE terminal_security Qt6::Test)
    add_test(NAME session_gate_flow COMMAND session_gate_test)
    add_executable(onboarding_test tests/onboarding_test.cpp)
    target_include_directories(onboarding_test PRIVATE src)
    target_link_libraries(onboarding_test PRIVATE terminal_core Qt6::Test)
    add_test(NAME onboarding_first_run COMMAND onboarding_test)
    set_tests_properties(onboarding_first_run PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 60)
    add_executable(security_lock_test tests/security_lock_test.cpp)
    target_link_libraries(security_lock_test PRIVATE terminal_core Qt6::Test)
    add_test(NAME security_lock_and_recovery COMMAND security_lock_test)
    add_executable(card_matcher_test tests/card_matcher_test.cpp)
    target_link_libraries(card_matcher_test PRIVATE terminal_security Qt6::Test)
    add_test(NAME card_index_matching COMMAND card_matcher_test)
    # T-12 Pi 侧验收（§0.8.7）：未配对拒发、挑战-响应失败拒发、指纹不匹配拒绝。
    add_executable(module_data_api_test tests/module_data_api_test.cpp)
    target_link_libraries(module_data_api_test PRIVATE terminal_core terminal_security Qt6::Test)
    add_test(NAME module_data_api_scope COMMAND module_data_api_test)
    add_executable(card_flow_test tests/card_flow_test.cpp)
    target_link_libraries(card_flow_test PRIVATE terminal_core terminal_security Qt6::Test)
    add_test(NAME card_selects_user_only COMMAND card_flow_test)
    add_executable(recovery_code_test tests/recovery_code_test.cpp)
    target_link_libraries(recovery_code_test PRIVATE terminal_security Qt6::Test)
    add_test(NAME recovery_code_path COMMAND recovery_code_test)
    add_executable(backup_test tests/backup_test.cpp)
    target_link_libraries(backup_test PRIVATE terminal_security Qt6::Test)
    add_test(NAME backup_restore_roundtrip COMMAND backup_test)
    add_executable(network_gate_test tests/network_gate_test.cpp)
    target_link_libraries(network_gate_test PRIVATE terminal_core Qt6::Test)
    add_test(NAME network_master_switch COMMAND network_gate_test)
    add_executable(app_network_broker_test tests/app_network_broker_test.cpp)
    target_link_libraries(app_network_broker_test PRIVATE terminal_core Qt6::Test)
    add_test(NAME module_network_broker_contract COMMAND app_network_broker_test)
    add_executable(file_daemon_test tests/file_daemon_test.cpp)
    target_compile_definitions(file_daemon_test PRIVATE
        FILE_DAEMON_BINARY="$<TARGET_FILE:orange-pi-file-daemon>")
    target_link_libraries(file_daemon_test PRIVATE terminal_core Qt6::Test)
    add_dependencies(file_daemon_test orange-pi-file-daemon)
    add_test(NAME file_daemon_contract COMMAND file_daemon_test)
    add_executable(net_policy_test tests/net_policy_test.cpp
        src/net/NetPolicy.cpp src/net/NetPolicy.h
        src/net/NetworkPolicy.cpp src/net/NetworkPolicy.h
        src/core/NetworkGate.cpp src/core/NetworkGate.h)
    target_include_directories(net_policy_test PRIVATE src)
    target_link_libraries(net_policy_test PRIVATE Qt6::Test Qt6::Core)
    add_test(NAME net_policy_contract COMMAND net_policy_test)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    add_test(NAME module_devkit_sync_check
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/../tools/sync_module_devkit.py --check)
    set_tests_properties(module_devkit_sync_check PROPERTIES TIMEOUT 30)
    add_test(NAME module_install_helper_contract
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tools/tests/test_module_install_helper.py)
    set_tests_properties(module_install_helper_contract PROPERTIES TIMEOUT 60)
    add_executable(pogo_control_test tests/pogo_control_test.cpp)
    target_link_libraries(pogo_control_test PRIVATE terminal_transports terminal_protocol Qt6::Test Qt6::SerialPort util)
    add_test(NAME pbr_command_aead COMMAND pogo_control_test)
    set_tests_properties(pbr_command_aead PROPERTIES TIMEOUT 30)
    add_executable(network_policy_qml_test tests/network_policy_qml_test.cpp)
    target_link_libraries(network_policy_qml_test PRIVATE terminal_ui Qt6::Quick Qt6::Test)
    # terminal_ui 没有符号被测试直接引用；--as-needed 会把整个 QML 资源
    # 共享库丢掉，qrc:/qt/qml/OrangePiTerminal 就找不到。显式保留。
    target_link_options(network_policy_qml_test PRIVATE "-Wl,--no-as-needed")
    add_test(NAME network_policy_qml_page COMMAND network_policy_qml_test)
    set_tests_properties(network_policy_qml_page PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software")

    add_executable(network_policy_controller_test tests/network_policy_controller_test.cpp)
    target_compile_definitions(network_policy_controller_test PRIVATE
        NET_POLICY_HELPER="$<TARGET_FILE:net_policy_helper>")
    target_link_libraries(network_policy_controller_test PRIVATE terminal_core Qt6::Test)
    add_dependencies(network_policy_controller_test net_policy_helper)
    add_test(NAME network_policy_controller COMMAND network_policy_controller_test)

    add_executable(test_runner_discovery_test tests/test_runner_discovery_test.cpp)
    target_compile_definitions(test_runner_discovery_test PRIVATE
        TEST_SOURCE_ROOT="${CMAKE_SOURCE_DIR}"
        TEST_BUILD_DIR="${CMAKE_BINARY_DIR}")
    target_link_libraries(test_runner_discovery_test PRIVATE terminal_core Qt6::Test)
    add_test(NAME test_runner_discovery COMMAND test_runner_discovery_test)

    add_executable(net_policy_helper_test tests/net_policy_helper_test.cpp)
    target_compile_definitions(net_policy_helper_test PRIVATE
        NET_POLICY_HELPER="$<TARGET_FILE:net_policy_helper>")
    target_link_libraries(net_policy_helper_test PRIVATE Qt6::Test Qt6::Core)
    add_dependencies(net_policy_helper_test net_policy_helper)
    add_test(NAME net_policy_helper_contract COMMAND net_policy_helper_test)

    add_executable(proxy_integration_test tests/proxy_integration_test.cpp
        src/net/ProxyServer.cpp src/net/ProxyServer.h src/net/NetChannels.h
        src/net/PublicNetwork.cpp src/net/PublicNetwork.h
        src/net/NetworkPolicy.cpp src/net/NetworkPolicy.h)
    target_include_directories(proxy_integration_test PRIVATE src)
    target_link_libraries(proxy_integration_test PRIVATE Qt6::Test Qt6::Network)
    target_compile_definitions(proxy_integration_test PRIVATE
        PROXY_BINARY="$<TARGET_FILE:network_proxy>")
    add_dependencies(proxy_integration_test network_proxy)
    add_test(NAME proxy_egress_contract COMMAND proxy_integration_test)
    set_tests_properties(proxy_egress_contract PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 60)
    add_executable(power_status_test tests/power_status_test.cpp)
    target_link_libraries(power_status_test PRIVATE terminal_core Qt6::Test)
    add_test(NAME power_status_semantics COMMAND power_status_test)
    add_executable(permission_matrix_test tests/permission_matrix_test.cpp)
    target_link_libraries(permission_matrix_test PRIVATE terminal_security Qt6::Test)
    add_test(NAME permission_mutual_exclusion COMMAND permission_matrix_test)
    add_executable(business_security_test tests/business_security_test.cpp)
    target_link_libraries(business_security_test PRIVATE
        terminal_transports terminal_protocol Qt6::Test Qt6::Network Qt6::Bluetooth)
    add_test(NAME business_data_security COMMAND business_security_test)
    add_executable(lane_gate_test tests/lane_gate_test.cpp)
    target_link_libraries(lane_gate_test PRIVATE terminal_core Qt6::Test)
    add_test(NAME business_lane_gate COMMAND lane_gate_test)
    add_executable(module_page_host_test tests/module_page_host_test.cpp)
    target_link_libraries(module_page_host_test PRIVATE terminal_core Qt6::Test Qt6::Qml Qt6::Quick)
    add_test(NAME module_page_engine_isolation COMMAND module_page_host_test)
    set_tests_properties(module_page_engine_isolation PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software")
    add_executable(worker_isolation_test tests/worker_isolation_test.cpp)
    target_include_directories(worker_isolation_test PRIVATE src)
    target_compile_definitions(worker_isolation_test PRIVATE
        WORKER_UNIT_PATH="${CMAKE_CURRENT_SOURCE_DIR}/packaging/orange-pi-worker@.service")
    target_link_libraries(worker_isolation_test PRIVATE terminal_core Qt6::Test)
    add_test(NAME worker_ipc_contract COMMAND worker_isolation_test)
    add_executable(runtime_test tests/runtime_test.cpp)
    add_executable(music_playback_test tests/music_playback_test.cpp)
    target_include_directories(music_playback_test PRIVATE src)
    target_link_libraries(music_playback_test PRIVATE terminal_music Qt6::Test)
    add_test(NAME music_playback_transactions COMMAND music_playback_test)
    add_executable(music_service_test tests/music_service_test.cpp
        src/net/ProxyServer.cpp src/net/ProxyServer.h
        src/net/PublicNetwork.cpp src/net/PublicNetwork.h
        src/net/NetworkPolicy.cpp src/net/NetworkPolicy.h)
    target_include_directories(music_service_test PRIVATE src)
    target_link_libraries(music_service_test PRIVATE terminal_music terminal_gate Qt6::Test Qt6::Network)
    add_test(NAME music_native_api_requests COMMAND music_service_test)
    add_executable(music_seek_test tests/music_seek_test.cpp)
    target_include_directories(music_seek_test PRIVATE src)
    target_link_libraries(music_seek_test PRIVATE terminal_system terminal_music terminal_ui Qt6::Test Qt6::QuickControls2 Qt6::Multimedia)
    add_test(NAME music_http_seek_clock COMMAND music_seek_test)
    # Qt 6.4 的 GStreamer 后端在"本地单线程 HTTP 夹具 + 立即 seek"这条路径上会停在
    # QMediaPlayer::LoadingMedia（180 s 超时），同一份测试在 Qt 6.5 / ffmpeg 后端 19 s 通过。
    # 这里显式指定 ffmpeg 后端；目标机若只带 GStreamer 插件，删掉这一项或升级 Qt 即可。
    set_tests_properties(music_http_seek_clock PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software;QT_MEDIA_BACKEND=ffmpeg" TIMEOUT 180)
    target_link_libraries(runtime_test PRIVATE terminal_core terminal_system Qt6::Test)
    add_test(NAME runtime_models_state_files COMMAND runtime_test)
    add_executable(plugin_scale_test tests/plugin_scale_test.cpp)
    add_executable(startup_splash_test tests/startup_splash_test.cpp)
    target_link_libraries(startup_splash_test PRIVATE terminal_ui Qt6::Test Qt6::QuickControls2 Qt6::Widgets)
    add_test(NAME startup_splash_lifecycle COMMAND startup_splash_test)
    add_executable(time_tools_test tests/time_tools_test.cpp)
    target_link_libraries(time_tools_test PRIVATE terminal_ui Qt6::Test Qt6::QuickControls2 Qt6::Network)
    add_test(NAME time_tools_page COMMAND time_tools_test)
    add_executable(time_sync_client_test tests/time_sync_client_test.cpp
        src/ui/TimeSyncClient.cpp src/ui/TimeSyncClient.h)
    target_include_directories(time_sync_client_test PRIVATE src)
    target_link_libraries(time_sync_client_test PRIVATE terminal_gate Qt6::Test Qt6::Network)
    add_test(NAME time_sync_client_contract COMMAND time_sync_client_test)
    set_tests_properties(time_sync_client_contract PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 30)
    set_tests_properties(time_tools_page PROPERTIES LABELS "interface"
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software" TIMEOUT 60)
    # 诊断探针：SQLCipher 在 WebEngine 初始化前后的耗时对比（不是 ctest，手工跑）。
    add_executable(db_webengine_probe tests/db_webengine_probe.cpp)
    target_link_libraries(db_webengine_probe PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Quick
                          Qt6::WebEngineQuick Qt6::Concurrent ${SQLCIPHER_LIB} OpenSSL::Crypto)
    target_include_directories(db_webengine_probe PRIVATE ${SQLCIPHER_INCLUDE_DIR})
    # SQLCipher 的 sqlite3_key 声明受这个宏控制（见 docs 里 R-18 的记录）。
    target_compile_definitions(db_webengine_probe PRIVATE SQLITE_HAS_CODEC)

    add_executable(weather_tools_test tests/weather_tools_test.cpp)
    target_link_libraries(weather_tools_test PRIVATE terminal_ui terminal_gate Qt6::Test Qt6::QuickControls2 Qt6::Network)
    add_test(NAME weather_tools_page COMMAND weather_tools_test)
    set_tests_properties(weather_tools_page PROPERTIES LABELS "interface"
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software" TIMEOUT 60)
    # 天气纯函数（直接执行线上那份 WeatherMath.js）。之前只能手动 node 跑，
    # 没人记得就没人跑，所以注册进 ctest；没有 node 的机器自动跳过。
    find_program(WEATHER_NODE_EXECUTABLE NAMES node nodejs)
    if(WEATHER_NODE_EXECUTABLE)
        add_test(NAME weather_math_functions
                 COMMAND ${WEATHER_NODE_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/weather_math_test.cjs)
        set_tests_properties(weather_math_functions PROPERTIES LABELS "unit" TIMEOUT 60)
    else()
        message(STATUS "node not found: weather_math_functions test skipped")
    endif()
    # D 写：设备配对授权页渲染回归（信任库有记录时，已配对桥板必须出现）。
    # 见 tests/pairing_ui_test.cpp 文件头；修好 delegate 之前本用例是红的。
    add_executable(pairing_ui_test tests/pairing_ui_test.cpp)
    target_link_libraries(pairing_ui_test PRIVATE terminal_ui Qt6::Test Qt6::QuickControls2)
    add_test(NAME pairing_ui_page COMMAND pairing_ui_test)
    set_tests_properties(pairing_ui_page PROPERTIES LABELS "interface"
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software" TIMEOUT 60)
    # 关于本机 →「开发者与感谢」名单页：入口存在、滑入、两个分段、关闭归位。
    add_executable(about_ui_test tests/about_ui_test.cpp)
    target_link_libraries(about_ui_test PRIVATE terminal_ui Qt6::Test Qt6::QuickControls2)
    add_test(NAME about_credits_page COMMAND about_ui_test)
    set_tests_properties(about_credits_page PROPERTIES LABELS "interface"
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software" TIMEOUT 60)
    # 应用卡片编辑模式：排序/持久化/取消恢复/恢复默认/模块置顶。
    add_executable(app_launcher_edit_test tests/app_launcher_edit_test.cpp)
    target_link_libraries(app_launcher_edit_test PRIVATE terminal_ui Qt6::Test Qt6::QuickControls2)
    add_test(NAME app_layout_edit COMMAND app_launcher_edit_test)
    set_tests_properties(app_layout_edit PROPERTIES LABELS "interface"
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software" TIMEOUT 60)
    add_executable(video_player_ui_test tests/video_player_ui_test.cpp)
    target_link_libraries(video_player_ui_test PRIVATE terminal_ui Qt6::Test Qt6::QuickControls2)
    add_test(NAME media_video_player_interface COMMAND video_player_ui_test)
    set_tests_properties(media_video_player_interface PROPERTIES LABELS "interface"
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software" TIMEOUT 30)
    add_executable(tv_player_ui_test tests/tv_player_ui_test.cpp)
    target_link_libraries(tv_player_ui_test PRIVATE terminal_ui Qt6::Test Qt6::QuickControls2)
    add_test(NAME media_tv_player_interface COMMAND tv_player_ui_test)
    set_tests_properties(media_tv_player_interface PROPERTIES LABELS "interface"
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software" TIMEOUT 30)
    set_tests_properties(startup_splash_lifecycle PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software")
    target_link_libraries(plugin_scale_test PRIVATE terminal_core Qt6::Test Qt6::Qml Qt6::Quick Qt6::Widgets)
    target_compile_definitions(plugin_scale_test PRIVATE PLUGIN_QML_PATH="${CMAKE_CURRENT_SOURCE_DIR}/modules/example/qml/ExamplePage.qml")
    add_test(NAME plugin_scale_geometry COMMAND plugin_scale_test)
    set_tests_properties(plugin_scale_geometry PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software")
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    add_test(NAME arkpets_worker_safety COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/character_worker_test.py)
    set_tests_properties(arkpets_worker_safety PROPERTIES ENVIRONMENT "PYTHONDONTWRITEBYTECODE=1")
    add_test(NAME arkpets_sprite_packing COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/pack_sprites_test.py)
    set_tests_properties(arkpets_sprite_packing PROPERTIES ENVIRONMENT "PYTHONDONTWRITEBYTECODE=1")
    if(UNIX AND NOT CMAKE_CROSSCOMPILING)
        add_test(NAME shared_runtime_install
            COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/shared_runtime_install.py
                    ${CMAKE_COMMAND} ${CMAKE_CURRENT_BINARY_DIR} ${TERMINAL_LIBRARY_DIR})
        # 用 SDK Qt（非系统 Qt）构建时，安装树 ldd 会按系统 SONAME 解析到旧版 Qt，
        # 报 "version Qt_6.5 not found"。把构建时实际使用的 Qt 库目录传给测试，
        # 只影响外部依赖解析；项目自身的 $ORIGIN 重定位仍由脚本原样校验。
        get_target_property(_qt_core_location Qt6::Core IMPORTED_LOCATION)
        if(NOT _qt_core_location)
            get_target_property(_qt_core_location Qt6::Core IMPORTED_LOCATION_RELEASE)
        endif()
        set(_shared_runtime_ld_paths)
        if(_qt_core_location)
            get_filename_component(_qt_lib_dir "${_qt_core_location}" DIRECTORY)
            list(APPEND _shared_runtime_ld_paths "${_qt_lib_dir}")
        endif()
        # 本地解包的 SQLCipher 不在系统默认搜索路径；安装树 ldd 必须能找到它。
        if(SQLCIPHER_LIB)
            get_filename_component(_sqlcipher_lib_dir "${SQLCIPHER_LIB}" DIRECTORY)
            list(APPEND _shared_runtime_ld_paths "${_sqlcipher_lib_dir}")
        endif()
        if(_shared_runtime_ld_paths)
            list(JOIN _shared_runtime_ld_paths ":" _shared_runtime_ld_path)
            set_tests_properties(shared_runtime_install PROPERTIES
                ENVIRONMENT "LD_LIBRARY_PATH=${_shared_runtime_ld_path}")
        endif()
        set_tests_properties(shared_runtime_install PROPERTIES TIMEOUT 60)
    endif()
    find_program(XVFB_RUN xvfb-run)
    if(NOT CMAKE_CROSSCOMPILING)
        if(XVFB_RUN)
            # UI audit needs an isolated admin profile; without it the app stops
            # at the login screen and every interaction assertion is meaningless.
            add_test(NAME ui_responsive_touch COMMAND ${XVFB_RUN} -a -s "-screen 0 2200x1800x24"
                ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_ui_audit.py
                $<TARGET_FILE:orange_pi_terminal> ${CMAKE_CURRENT_BINARY_DIR}/ui-audit)
            add_test(NAME ui_highdpi_touch COMMAND ${CMAKE_COMMAND} -E env QT_SCALE_FACTOR=1.5
                ${XVFB_RUN} -a -s "-screen 0 3200x2400x24"
                ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_ui_audit.py
                $<TARGET_FILE:orange_pi_terminal> ${CMAKE_CURRENT_BINARY_DIR}/ui-audit-hidpi)
            set_tests_properties(ui_responsive_touch ui_highdpi_touch PROPERTIES TIMEOUT 120)
        endif()
        add_test(NAME signed_package_integration COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_integration.py ${CMAKE_CURRENT_BINARY_DIR})
        # GUI 集成用例会起 xvfb + WebEngine，和其他用例并行时会被 CPU 抢占导致 ui-test
        # 在 7 s 内跑不完（退出码 3）；这里禁止它与别人并行。
        set_tests_properties(signed_package_integration PROPERTIES TIMEOUT 260 RUN_SERIAL TRUE)
    endif()
endif()
# KDF 子进程：把 600k 次 PBKDF2 挪出主线程（进程隔离，避免 SQLite/OpenSSL
# 的进程级全局状态跨线程自锁）。主进程用 applicationDirPath()/terminal_kdf_worker 找它。
add_executable(terminal_kdf_worker src/security/kdf_worker_main.cpp)
target_link_libraries(terminal_kdf_worker PRIVATE terminal_security)
set_target_properties(terminal_kdf_worker PROPERTIES POSITION_INDEPENDENT_CODE ON)

install(TARGETS orange_pi_terminal RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR} COMPONENT TerminalRuntime)
# T-11：worker 二进制必须安装，否则 systemd unit 永远起不来，
# 产品只能走 QProcess 降级路径（无隔离）。
install(TARGETS module_worker RUNTIME DESTINATION ${CMAKE_INSTALL_LIBEXECDIR}/orange-pi-terminal
        COMPONENT TerminalRuntime)
# systemd 单元随安装包提供；安装到系统目录需用户执行一次 sudo。
install(FILES packaging/orange-pi-worker@.service
        DESTINATION share/orange-pi-terminal/systemd COMPONENT TerminalRuntime)
# 出站代理必须随包安装：主进程把它当子进程拉起，四条网络栈也都指向它。
# 缺了它 = 所有外网请求失败（fail-closed），不是"降级"。
install(TARGETS network_proxy RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        COMPONENT TerminalRuntime)
install(TARGETS orange-pi-file-daemon RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        COMPONENT TerminalRuntime)
install(FILES packaging/orange-pi-file-daemon.service
        DESTINATION share/orange-pi-terminal/systemd COMPONENT TerminalRuntime)
install(TARGETS terminal_kdf_worker RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        COMPONENT TerminalRuntime)
install(FILES packaging/orange-pi-net-proxy.service packaging/net-egress.sh
        DESTINATION share/orange-pi-terminal/systemd COMPONENT TerminalRuntime)
install(TARGETS net_policy_helper RUNTIME DESTINATION ${CMAKE_INSTALL_LIBEXECDIR}/orange-pi-terminal
        COMPONENT TerminalRuntime)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/com.orangepi.terminal.network-policy.policy"
        DESTINATION share/polkit-1/actions COMPONENT TerminalRuntime)
install(TARGETS terminal_music terminal_system terminal_ui LIBRARY DESTINATION ${TERMINAL_LIBRARY_DIR} COMPONENT TerminalRuntime)
install(FILES music_api/server.cjs music_api/package.json music_api/package-lock.json DESTINATION libexec/orange-pi-terminal/music-api)
install(DIRECTORY music_api/node_modules/ DESTINATION libexec/orange-pi-terminal/music-api/node_modules OPTIONAL)
install(FILES tools/package_tool.py DESTINATION libexec/orange-pi-terminal)
install(PROGRAMS tools/module_install_helper.py DESTINATION libexec/orange-pi-terminal)
install(FILES tools/arkpets/character_worker.py tools/arkpets/pack_sprites.py
    tools/arkpets/ExportSprites.java tools/arkpets/runtime-lock.json
    DESTINATION libexec/orange-pi-terminal/arkpets COMPONENT TerminalRuntime)
install(FILES assets/arkpets/NOTICE.md assets/arkpets/ARK-MODELS-NOTICE.md
    assets/arkpets/SPINE-RUNTIMES-LICENSE.txt assets/arkpets/SOURCES.json
    DESTINATION share/orange-pi-terminal/licenses/arkpets COMPONENT TerminalRuntime)
install(FILES config/product.example.json DESTINATION share/orange-pi-terminal RENAME product.example.json)
install(FILES config/product.ble.example.json config/product.ble-hotspot-package.example.json config/product.lan.example.json DESTINATION share/orange-pi-terminal/examples)
install(FILES config/environment.example DESTINATION share/orange-pi-terminal)
install(FILES qml/icons/LICENSE qml/icons/NOTICE DESTINATION share/orange-pi-terminal/licenses/material-icons)
install(FILES ../third_party/Viper-Browser/LICENSE ../third_party/Viper-Browser/README.md
    DESTINATION share/orange-pi-terminal/licenses/viper-browser COMPONENT TerminalRuntime)
install(FILES ../third_party/vlc/README.md ../third_party/vlc/VlcVideoItem.h
    ../third_party/vlc/VlcVideoItem.cpp ../third_party/vlc/CMakeLists.txt
    DESTINATION share/orange-pi-terminal/source/vlc COMPONENT TerminalRuntime)
install(DIRECTORY ../third_party/Viper-Browser/
    DESTINATION share/orange-pi-terminal/source/Viper-Browser
    COMPONENT TerminalRuntime PATTERN ".git" EXCLUDE)
install(DIRECTORY ../third_party/sqlite-amalgamation/
    DESTINATION share/orange-pi-terminal/third-party/sqlite-amalgamation
    COMPONENT TerminalRuntime FILES_MATCHING PATTERN "sqlite3.c" PATTERN "sqlite3.h")
install(FILES qml/icons/material/NOTICE qml/icons/material/SOURCES.json DESTINATION share/orange-pi-terminal/licenses/material-icons/round)
install(FILES assets/ringtones/NOTICE.md DESTINATION share/orange-pi-terminal/licenses/ringtones)
install(FILES assets/fonts/OFL.txt assets/fonts/TRADEMARKS.md DESTINATION share/orange-pi-terminal/licenses/google-sans)
install(FILES assets/pinyin/LICENSE assets/pinyin/AUTHORS assets/pinyin/PYPINYIN-LICENSE assets/pinyin/SOURCES.md DESTINATION share/orange-pi-terminal/licenses/pinyin)
install(TARGETS pi_module_sdk EXPORT OrangePiModuleSDKTargets)
install(EXPORT OrangePiModuleSDKTargets NAMESPACE OrangePi:: DESTINATION lib/cmake/OrangePiModuleSDK)
install(FILES cmake/OrangePiModuleSDKConfig.cmake DESTINATION lib/cmake/OrangePiModuleSDK)
install(FILES src/modules/api/pi_module_api.h src/modules/api/IModulePlugin.h DESTINATION include/orange-pi-terminal)
