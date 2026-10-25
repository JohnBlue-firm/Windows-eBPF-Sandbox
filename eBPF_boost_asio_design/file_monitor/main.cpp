#include "ActionLoop.hpp"
#include "DirectoryWatcher.hpp"

#include <iostream>
#include <memory>
#include <string>

namespace {

const wchar_t* action_name(DWORD action)
{
    switch (action) {
    case FILE_ACTION_ADDED: return L"added";
    case FILE_ACTION_REMOVED: return L"removed";
    case FILE_ACTION_MODIFIED: return L"modified";
    case FILE_ACTION_RENAMED_OLD_NAME: return L"rename-from";
    case FILE_ACTION_RENAMED_NEW_NAME: return L"rename-to";
    default: return L"unknown";
    }
}

class FileChangeLogAction final : public IAction {
public:
    explicit FileChangeLogAction(FileChange change)
        : change_(std::move(change))
    {
    }

    boost::asio::awaitable<void> execute_async() override
    {
        std::wcout << action_name(change_.action) << L": " << change_.relative_path << L'\n';
        co_return;
    }

private:
    FileChange change_;
};

} // namespace

int wmain(int argc, wchar_t* argv[])
{
    if (argc != 2) {
        std::wcerr << L"Usage: file_change_monitor <directory>\n";
        return 2;
    }

    try {
        DirectoryWatcher watcher(argv[1], [](FileChange change) {
            ActionLoop::getInstance().pushAction(
                std::make_unique<FileChangeLogAction>(std::move(change)));
        });
        watcher.start();
        std::wcout << L"Watching " << argv[1]
                   << L" for completed changes. Press Enter to stop.\n"
                   << L"This sample cannot block or undo file operations; use a Minifilter for enforcement.\n";
        std::wstring line;
        std::getline(std::wcin, line);
        watcher.stop();
    } catch (const std::exception& error) {
        std::cerr << "File monitor failed: " << error.what() << '\n';
        return 1;
    }
    return 0;
}