cmake_minimum_required(VERSION 3.24)
project(windows_ebpf_boost_asio LANGUAGES CXX)

include(FetchContent)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(EBPF_FOR_WINDOWS_COMMIT "b7a8dd217a608719b03afe848cc4d5206445fbda" CACHE STRING "Pinned eBPF for Windows headers")
set(XDP_FOR_WINDOWS_COMMIT "6fda82cba9712b0a0aac132e507c0945924d5209" CACHE STRING "Pinned XDP for Windows headers")

FetchContent_Declare(ebpf_for_windows_headers
    URL "https://github.com/microsoft/ebpf-for-windows/archive/${EBPF_FOR_WINDOWS_COMMIT}.tar.gz"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_Declare(xdp_for_windows_headers
    URL "https://github.com/microsoft/xdp-for-windows/archive/${XDP_FOR_WINDOWS_COMMIT}.tar.gz"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_GetProperties(ebpf_for_windows_headers)
if(NOT ebpf_for_windows_headers_POPULATED)
    FetchContent_Populate(ebpf_for_windows_headers)
endif()
FetchContent_GetProperties(xdp_for_windows_headers)
if(NOT xdp_for_windows_headers_POPULATED)
    FetchContent_Populate(xdp_for_windows_headers)
endif()

find_package(Threads REQUIRED)

set(BOOST_VERSION 1.86.0 CACHE STRING "Boost version fetched for header-only Asio")
set(BOOST_ARCHIVE_VERSION "${BOOST_VERSION}")
string(REPLACE "." "_" BOOST_ARCHIVE_VERSION "${BOOST_ARCHIVE_VERSION}")

FetchContent_Declare(boost_headers
    URL "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_ARCHIVE_VERSION}.tar.gz"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_GetProperties(boost_headers)
if(NOT boost_headers_POPULATED)
    FetchContent_Populate(boost_headers)
endif()

add_library(boost_headers INTERFACE)
target_include_directories(boost_headers SYSTEM INTERFACE "${boost_headers_SOURCE_DIR}")

add_executable(asio_smoke_test
    actions/ActionLoop.cpp
    actions/main.cpp
)
target_include_directories(asio_smoke_test PRIVATE actions)
target_link_libraries(asio_smoke_test PRIVATE boost_headers Threads::Threads)

find_program(BPF_CLANG_EXECUTABLE NAMES clang clang-18 REQUIRED)
set(BPF_OUTPUT_DIR "${CMAKE_BINARY_DIR}/bpf")
set(XDP_PASS_OBJECT "${BPF_OUTPUT_DIR}/xdp_pass.bpf.o")
set(BIND_POLICY_OBJECT "${BPF_OUTPUT_DIR}/bind_policy.bpf.o")

add_custom_command(
    OUTPUT "${XDP_PASS_OBJECT}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${BPF_OUTPUT_DIR}"
    COMMAND "${BPF_CLANG_EXECUTABLE}" -O2 -g -ffreestanding -target bpf
        "-I${ebpf_for_windows_headers_SOURCE_DIR}/include"
        "-I${xdp_for_windows_headers_SOURCE_DIR}/published/external"
        -c "${CMAKE_CURRENT_SOURCE_DIR}/xdp/xdp_pass.bpf.c"
        -o "${XDP_PASS_OBJECT}"
    DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/xdp/xdp_pass.bpf.c"
        "${ebpf_for_windows_headers_SOURCE_DIR}/include/bpf_helpers.h"
        "${xdp_for_windows_headers_SOURCE_DIR}/published/external/xdp/ebpfhook.h"
    COMMENT "Compiling Windows XDP pass-through program"
    VERBATIM
)

add_custom_command(
    OUTPUT "${BIND_POLICY_OBJECT}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${BPF_OUTPUT_DIR}"
    COMMAND "${BPF_CLANG_EXECUTABLE}" -O2 -g -ffreestanding -target bpf
        "-I${ebpf_for_windows_headers_SOURCE_DIR}/include"
        -c "${CMAKE_CURRENT_SOURCE_DIR}/socket_address/bind_policy.bpf.c"
        -o "${BIND_POLICY_OBJECT}"
    DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/socket_address/bind_policy.bpf.c"
        "${ebpf_for_windows_headers_SOURCE_DIR}/include/bpf_helpers.h"
        "${ebpf_for_windows_headers_SOURCE_DIR}/include/ebpf_nethooks.h"
    COMMENT "Compiling Windows socket-address bind policy"
    VERBATIM
)
add_custom_target(windows_ebpf_programs ALL DEPENDS "${XDP_PASS_OBJECT}" "${BIND_POLICY_OBJECT}")

if(WIN32)
    add_executable(file_change_monitor
        actions/ActionLoop.cpp
        file_monitor/DirectoryWatcher.cpp
        file_monitor/main.cpp
    )
    target_include_directories(file_change_monitor PRIVATE actions file_monitor)
    target_link_libraries(file_change_monitor PRIVATE boost_headers Threads::Threads)
    target_compile_definitions(file_change_monitor PRIVATE _WIN32_WINNT=0x0A00 WINVER=0x0A00)

    add_executable(etw_process_monitor
        actions/ActionLoop.cpp
        etw/KernelProcessWatcher.cpp
        etw/main.cpp
    )
    target_include_directories(etw_process_monitor PRIVATE actions etw)
    target_link_libraries(etw_process_monitor PRIVATE boost_headers Threads::Threads Advapi32 Ole32)
    target_compile_definitions(etw_process_monitor PRIVATE _WIN32_WINNT=0x0A00 WINVER=0x0A00)
endif()

if(MSVC)
    target_compile_options(asio_smoke_test PRIVATE /W4 /permissive-)
    if(WIN32)
        target_compile_options(file_change_monitor PRIVATE /W4 /permissive-)
        target_compile_options(etw_process_monitor PRIVATE /W4 /permissive-)
    endif()
else()
    target_compile_options(asio_smoke_test PRIVATE -Wall -Wextra -Wpedantic)
endif()