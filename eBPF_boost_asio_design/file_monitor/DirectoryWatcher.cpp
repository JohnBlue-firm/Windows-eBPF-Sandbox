#include "DirectoryWatcher.hpp"

#include <array>
#include <cstddef>
#include <iostream>
#include <stdexcept>
#include <system_error>
#include <utility>

namespace {

[[noreturn]] void throw_windows_error(const char* operation)
{
    throw std::system_error(
        static_cast<int>(GetLastError()), std::system_category(), operation);
}

class unique_handle {
public:
    explicit unique_handle(HANDLE handle = nullptr) noexcept
        : handle_(handle)
    {
    }

    ~unique_handle()
    {
        if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
            CloseHandle(handle_);
        }
    }

    unique_handle(const unique_handle&) = delete;
    unique_handle& operator=(const unique_handle&) = delete;

    HANDLE get() const noexcept { return handle_; }

private:
    HANDLE handle_;
};

void report_file_changes(
    const std::byte* buffer, DWORD bytes_transferred, const DirectoryWatcher::ChangeHandler& on_change)
{
    std::size_t offset = 0;
    while (offset + offsetof(FILE_NOTIFY_INFORMATION, FileName) <= bytes_transferred) {
        const auto* notification = reinterpret_cast<const FILE_NOTIFY_INFORMATION*>(buffer + offset);
        const auto name_bytes = static_cast<std::size_t>(notification->FileNameLength);
        const auto record_size = offsetof(FILE_NOTIFY_INFORMATION, FileName) + name_bytes;

        if (name_bytes % sizeof(wchar_t) != 0 || offset + record_size > bytes_transferred) {
            throw std::runtime_error("ReadDirectoryChangesW returned a malformed notification record");
        }

        try {
            on_change(FileChange{
                std::wstring(notification->FileName, name_bytes / sizeof(wchar_t)),
                notification->Action,
            });
        } catch (const std::exception& error) {
            std::cerr << "File-change callback failed: " << error.what() << '\n';
        } catch (...) {
            std::cerr << "File-change callback failed with an unknown exception\n";
        }

        if (notification->NextEntryOffset == 0) {
            break;
        }
        if (notification->NextEntryOffset < record_size ||
            offset + notification->NextEntryOffset > bytes_transferred) {
            throw std::runtime_error("ReadDirectoryChangesW returned an invalid record offset");
        }
        offset += notification->NextEntryOffset;
    }
}

} // namespace

DirectoryWatcher::DirectoryWatcher(std::wstring directory, ChangeHandler on_change)
    : directory_(std::move(directory))
    , on_change_(std::move(on_change))
{
    if (directory_.empty() || !on_change_) {
        throw std::invalid_argument("DirectoryWatcher requires a directory and a change handler");
    }
}

DirectoryWatcher::~DirectoryWatcher()
{
    stop();
}

void DirectoryWatcher::start()
{
    if (worker_.joinable()) {
        throw std::logic_error("DirectoryWatcher is already running");
    }

    stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (stop_event_ == nullptr) {
        throw_windows_error("CreateEventW");
    }

    try {
        worker_ = std::thread(&DirectoryWatcher::run, this);
    } catch (...) {
        CloseHandle(stop_event_);
        stop_event_ = nullptr;
        throw;
    }
}

void DirectoryWatcher::stop()
{
    if (!worker_.joinable()) {
        return;
    }
    SetEvent(stop_event_);
    worker_.join();
    CloseHandle(stop_event_);
    stop_event_ = nullptr;
}

void DirectoryWatcher::run()
{
    unique_handle directory_handle(CreateFileW(
        directory_.c_str(),
        FILE_LIST_DIRECTORY,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
        nullptr));
    if (directory_handle.get() == INVALID_HANDLE_VALUE) {
        std::cerr << "Cannot open directory for watching (Win32 error " << GetLastError() << ")\n";
        return;
    }

    alignas(FILE_NOTIFY_INFORMATION) std::array<std::byte, 64 * 1024> buffer{};
    while (WaitForSingleObject(stop_event_, 0) == WAIT_TIMEOUT) {
        unique_handle completion_event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        if (completion_event.get() == nullptr) {
            std::cerr << "Cannot create completion event (Win32 error " << GetLastError() << ")\n";
            return;
        }

        OVERLAPPED overlapped{};
        overlapped.hEvent = completion_event.get();
        const BOOL started = ReadDirectoryChangesW(
            directory_handle.get(),
            buffer.data(),
            static_cast<DWORD>(buffer.size()),
            TRUE,
            FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SIZE |
                FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_CREATION,
            nullptr,
            &overlapped,
            nullptr);

        if (!started && GetLastError() != ERROR_IO_PENDING) {
            std::cerr << "ReadDirectoryChangesW failed (Win32 error " << GetLastError() << ")\n";
            return;
        }

        HANDLE wait_handles[] = {stop_event_, completion_event.get()};
        const DWORD wait_result = WaitForMultipleObjects(2, wait_handles, FALSE, INFINITE);
        if (wait_result == WAIT_OBJECT_0) {
            CancelIoEx(directory_handle.get(), &overlapped);
            DWORD ignored_bytes = 0;
            GetOverlappedResult(directory_handle.get(), &overlapped, &ignored_bytes, TRUE);
            return;
        }
        if (wait_result != WAIT_OBJECT_0 + 1) {
            CancelIoEx(directory_handle.get(), &overlapped);
            DWORD ignored_bytes = 0;
            GetOverlappedResult(directory_handle.get(), &overlapped, &ignored_bytes, TRUE);
            std::cerr << "Waiting for directory changes failed (Win32 error " << GetLastError() << ")\n";
            return;
        }

        DWORD bytes_transferred = 0;
        if (!GetOverlappedResult(directory_handle.get(), &overlapped, &bytes_transferred, FALSE)) {
            const DWORD error = GetLastError();
            if (error == ERROR_OPERATION_ABORTED) {
                return;
            }
            std::cerr << "Reading directory changes failed (Win32 error " << error << ")\n";
            return;
        }
        if (bytes_transferred == 0) {
            std::cerr << "ReadDirectoryChangesW buffer overflowed; rescan the directory for missed changes.\n";
            continue;
        }

        try {
            report_file_changes(buffer.data(), bytes_transferred, on_change_);
        } catch (const std::exception& error) {
            std::cerr << error.what() << '\n';
            return;
        }
    }
}