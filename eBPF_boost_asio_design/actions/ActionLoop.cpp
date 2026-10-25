#include "ActionLoop.hpp"

#include <exception>
#include <iostream>
#include <stdexcept>
#include <utility>

#include <boost/asio/co_spawn.hpp>

namespace asio = boost::asio;

ActionLoop::ActionLoop()
    : work_guard_(asio::make_work_guard(io_context_))
    , thread_([this] { io_context_.run(); })
{
}

ActionLoop::~ActionLoop()
{
    stopping_.store(true, std::memory_order_relaxed);
    work_guard_.reset();
    io_context_.stop();
    if (thread_.joinable()) {
        thread_.join();
    }
}

ActionLoop& ActionLoop::getInstance()
{
    static ActionLoop instance;
    return instance;
}

asio::awaitable<void> ActionLoop::executeAction(std::shared_ptr<IAction> action)
{
    co_await action->execute_async();
}

void ActionLoop::pushAction(std::unique_ptr<IAction> action)
{
    if (!action) {
        throw std::invalid_argument("ActionLoop does not accept a null action");
    }
    if (stopping_.load(std::memory_order_relaxed)) {
        throw std::runtime_error("ActionLoop is stopping");
    }

    auto shared_action = std::shared_ptr<IAction>(std::move(action));
    asio::co_spawn(
        io_context_,
        executeAction(std::move(shared_action)),
        [](std::exception_ptr error) {
            if (error) {
                try {
                    std::rethrow_exception(error);
                } catch (const std::exception& exception) {
                    std::cerr << "Action failed: " << exception.what() << '\n';
                } catch (...) {
                    std::cerr << "Action failed with an unknown exception\n";
                }
            }
        });
}