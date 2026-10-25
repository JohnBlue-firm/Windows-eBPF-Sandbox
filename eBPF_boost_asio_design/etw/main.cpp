#include "ActionLoop.hpp"
#include "KernelProcessWatcher.hpp"

#include <iostream>
#include <memory>
#include <string>

class EtwLogAction final : public IAction {
public:
    explicit EtwLogAction(KernelProcessEvent event)
        : event_(event)
    {
    }

    boost::asio::awaitable<void> execute_async() override
    {
        std::cout << "Kernel-Process ETW event id=" << event_.event_id
                  << " opcode=" << static_cast<unsigned>(event_.opcode)
                  << " pid=" << event_.process_id
                  << " tid=" << event_.thread_id << '\n';
        co_return;
    }

private:
    KernelProcessEvent event_;
};

int wmain()
{
    try {
        KernelProcessWatcher watcher([](KernelProcessEvent event) {
            ActionLoop::getInstance().pushAction(std::make_unique<EtwLogAction>(event));
        });
        watcher.start();
        std::cout << "Listening to Microsoft-Windows-Kernel-Process ETW. Press Enter to stop.\n";
        std::string line;
        std::getline(std::cin, line);
        watcher.stop();
    } catch (const std::exception& error) {
        std::cerr << "ETW monitor failed: " << error.what()
                  << ". Run elevated if the ETW provider requires administrator privileges.\n";
        return 1;
    }
    return 0;
}