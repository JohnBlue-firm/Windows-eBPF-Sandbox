#pragma once

#include <atomic>
#include <memory>
#include <thread>

#include <boost/asio/awaitable.hpp>
#include <boost/asio/executor_work_guard.hpp>
#include <boost/asio/io_context.hpp>

class IAction {
public:
    virtual ~IAction() = default;
    virtual boost::asio::awaitable<void> execute_async() = 0;
};

class ActionLoop {
public:
    ActionLoop(const ActionLoop&) = delete;
    ActionLoop& operator=(const ActionLoop&) = delete;

    static ActionLoop& getInstance();
    ~ActionLoop();

    void pushAction(std::unique_ptr<IAction> action);

private:
    ActionLoop();
    static boost::asio::awaitable<void> executeAction(std::shared_ptr<IAction> action);

    boost::asio::io_context io_context_;
    boost::asio::executor_work_guard<boost::asio::io_context::executor_type> work_guard_;
    std::thread thread_;
    std::atomic_bool stopping_{false};
};