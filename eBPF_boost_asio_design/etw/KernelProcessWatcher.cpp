#include "KernelProcessWatcher.hpp"

#include <windows.h>
#include <evntcons.h>
#include <evntrace.h>
#include <objbase.h>

#include <algorithm>
#include <cstddef>
#include <iostream>
#include <stdexcept>
#include <system_error>
#include <utility>
#include <vector>

namespace {

constexpr GUID kernel_process_provider = {
    0x22fb2cd6, 0x0e7b, 0x422b, {0xa0, 0xc7, 0x2f, 0xad, 0x1f, 0xd0, 0xe7, 0x16}};

[[noreturn]] void throw_etw_error(ULONG status, const char* operation)
{
    throw std::system_error(static_cast<int>(status), std::system_category(), operation);
}

} // namespace

KernelProcessWatcher::KernelProcessWatcher(EventHandler on_event)
    : on_event_(std::move(on_event))
    , session_name_(L"WindowsEbpfKernelProcess-")
{
    if (!on_event_) {
        throw std::invalid_argument("KernelProcessWatcher requires an event handler");
    }
    session_name_ += std::to_wstring(GetCurrentProcessId());
}

KernelProcessWatcher::~KernelProcessWatcher()
{
    stop();
}

void KernelProcessWatcher::start()
{
    if (worker_.joinable()) {
        throw std::logic_error("KernelProcessWatcher is already running");
    }

    constexpr std::size_t logger_name_bytes = 256 * sizeof(wchar_t);
    properties_buffer_.assign(sizeof(EVENT_TRACE_PROPERTIES) + logger_name_bytes, std::byte{});
    properties_ = reinterpret_cast<EVENT_TRACE_PROPERTIES*>(properties_buffer_.data());
    ZeroMemory(properties_, properties_buffer_.size());
    properties_->Wnode.BufferSize = static_cast<ULONG>(properties_buffer_.size());
    properties_->Wnode.Flags = WNODE_FLAG_TRACED_GUID;
    properties_->Wnode.ClientContext = 1;
    properties_->LogFileMode = EVENT_TRACE_REAL_TIME_MODE;
    properties_->LoggerNameOffset = sizeof(EVENT_TRACE_PROPERTIES);
    auto* logger_name = reinterpret_cast<wchar_t*>(
        reinterpret_cast<std::byte*>(properties_) + properties_->LoggerNameOffset);
    std::copy(session_name_.begin(), session_name_.end(), logger_name);
    logger_name[session_name_.size()] = L'\0';

    const HRESULT guid_status = CoCreateGuid(&properties_->Wnode.Guid);
    if (FAILED(guid_status)) {
        properties_ = nullptr;
        properties_buffer_.clear();
        throw_etw_error(static_cast<ULONG>(guid_status), "CoCreateGuid");
    }

    const ULONG start_status = StartTraceW(&session_handle_, session_name_.data(), properties_);
    if (start_status != ERROR_SUCCESS) {
        properties_ = nullptr;
        properties_buffer_.clear();
        throw_etw_error(start_status, "StartTraceW");
    }

    const ULONG enable_status = EnableTraceEx2(
        session_handle_,
        &kernel_process_provider,
        EVENT_CONTROL_CODE_ENABLE_PROVIDER,
        TRACE_LEVEL_VERBOSE,
        0xFFFFFFFFFFFFFFFFULL,
        0,
        0,
        nullptr);
    if (enable_status != ERROR_SUCCESS) {
        stop();
        throw_etw_error(enable_status, "EnableTraceEx2");
    }

    EVENT_TRACE_LOGFILEW logfile{};
    logfile.LoggerName = session_name_.data();
    logfile.ProcessTraceMode = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
    logfile.EventRecordCallback = &KernelProcessWatcher::handle_event;
    logfile.Context = this;
    trace_handle_ = OpenTraceW(&logfile);
    if (trace_handle_ == INVALID_PROCESSTRACE_HANDLE) {
        const ULONG error = GetLastError();
        stop();
        throw_etw_error(error, "OpenTraceW");
    }

    try {
        worker_ = std::thread(&KernelProcessWatcher::consume_events, this);
    } catch (...) {
        CloseTrace(trace_handle_);
        trace_handle_ = INVALID_PROCESSTRACE_HANDLE;
        stop();
        throw;
    }
    storage.release();
}

void KernelProcessWatcher::stop()
{
    if (session_handle_ != 0 && properties_ != nullptr) {
        ControlTraceW(session_handle_, session_name_.data(), properties_, EVENT_TRACE_CONTROL_STOP);
        session_handle_ = 0;
    }
    if (worker_.joinable()) {
        worker_.join();
    }
    if (trace_handle_ != INVALID_PROCESSTRACE_HANDLE) {
        CloseTrace(trace_handle_);
        trace_handle_ = INVALID_PROCESSTRACE_HANDLE;
    }
    if (properties_ != nullptr) {
        properties_ = nullptr;
        properties_buffer_.clear();
    }
}

void WINAPI KernelProcessWatcher::handle_event(PEVENT_RECORD record)
{
    auto* watcher = static_cast<KernelProcessWatcher*>(record->UserContext);
    if (watcher != nullptr) {
        watcher->process_event(record);
    }
}

void KernelProcessWatcher::process_event(PEVENT_RECORD record) noexcept
{
    try {
        on_event_(KernelProcessEvent{
            record->EventHeader.EventDescriptor.Id,
            record->EventHeader.EventDescriptor.Opcode,
            record->EventHeader.ProcessId,
            record->EventHeader.ThreadId,
        });
    } catch (const std::exception& error) {
        std::cerr << "ETW callback failed: " << error.what() << '\n';
    } catch (...) {
        std::cerr << "ETW callback failed with an unknown exception\n";
    }
}

void KernelProcessWatcher::consume_events() noexcept
{
    const ULONG status = ProcessTrace(&trace_handle_, 1, nullptr, nullptr);
    if (status != ERROR_SUCCESS && status != ERROR_CANCELLED) {
        std::cerr << "ProcessTrace failed (Win32 error " << status << ")\n";
    }
}