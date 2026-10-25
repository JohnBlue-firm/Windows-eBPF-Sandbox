#pragma once

#ifndef _WIN32
#error "DirectoryWatcher is available only on Windows."
#endif

#include <windows.h>

#include <functional>
#include <string>
#include <thread>

struct FileChange {
    std::wstring relative_path;
    DWORD action;
};

// Observes completed filesystem changes only. Use a Minifilter to enforce or deny operations.
class DirectoryWatcher {
public:
    using ChangeHandler = std::function<void(FileChange)>;

    DirectoryWatcher(std::wstring directory, ChangeHandler on_change);
    DirectoryWatcher(const DirectoryWatcher&) = delete;
    DirectoryWatcher& operator=(const DirectoryWatcher&) = delete;
    ~DirectoryWatcher();

    void start();
    void stop();

private:
    void run();

    std::wstring directory_;
    ChangeHandler on_change_;
    HANDLE stop_event_{nullptr};
    std::thread worker_;
};