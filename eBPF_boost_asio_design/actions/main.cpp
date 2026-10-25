#include "ActionLoop.hpp"

#include <chrono>
#include <future>
#include <iostream>
#include <memory>

#include <boost/asio/steady_timer.hpp>
#include <boost/asio/this_coro.hpp>
#include <boost/asio/use_awaitable.hpp>

namespace asio = boost::asio;

class SmokeTestAction final : public IAction {
public:
    explicit SmokeTestAction(std::promise<void>& completed)
        : completed_(completed)
    {
    }

    asio::awaitable<void> execute_async() override
    {
        asio::steady_timer timer(co_await asio::this_coro::executor);
        timer.expires_after(std::chrono::milliseconds(10));
        co_await timer.async_wait(asio::use_awaitable);
        std::cout << "Boost.Asio action completed\n";
        completed_.set_value();
    }

private:
    std::promise<void>& completed_;
};

int main()
{
    std::promise<void> completed;
    auto result = completed.get_future();
    ActionLoop::getInstance().pushAction(std::make_unique<SmokeTestAction>(completed));
    result.get();
    return 0;
}