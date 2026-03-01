#include "mavlink_quic_relay/reconnect_manager.h"

#include <chrono>
#include <random>
#include <thread>

#include <ros/ros.h>

namespace mavlink_quic_relay {

ReconnectManager::ReconnectManager(QuicClient& client, RosInterface& ros_iface)
    : quic_client_(client)
    , ros_iface_(ros_iface)
    , rng_(std::random_device{}())
{
}

ReconnectManager::~ReconnectManager()
{
    stop();
}

void ReconnectManager::start()
{
    running_.store(true, std::memory_order_relaxed);
    reconnect_thread_ = std::thread(&ReconnectManager::reconnectLoop, this);
}

void ReconnectManager::stop()
{
    running_.store(false, std::memory_order_relaxed);
    reconnect_cv_.notify_all();
    if (reconnect_thread_.joinable()) {
        reconnect_thread_.join();
    }
}

void ReconnectManager::onConnected()
{
    state_.store(State::AUTHENTICATING, std::memory_order_relaxed);
    reconnect_attempts_ = 0;
    ROS_INFO("mavlink_quic_relay: QUIC connection established, waiting for AUTH");
}

void ReconnectManager::onDisconnected()
{
    state_.store(State::DISCONNECTED, std::memory_order_relaxed);
    ros_iface_.clearOutboundQueue();
    should_reconnect_.store(true, std::memory_order_relaxed);
    reconnect_cv_.notify_one();
    ROS_WARN("mavlink_quic_relay: QUIC connection lost, scheduling reconnect");
}

void ReconnectManager::onAuthOk()
{
    state_.store(State::CONNECTED, std::memory_order_relaxed);
    ROS_INFO("mavlink_quic_relay: AUTH OK — relay is active");
}

void ReconnectManager::onAuthFailed()
{
    state_.store(State::DISCONNECTED, std::memory_order_relaxed);
    auth_failure_pending_ = true;
    should_reconnect_.store(true, std::memory_order_relaxed);
    reconnect_cv_.notify_one();
    ROS_ERROR("mavlink_quic_relay: AUTH failed — 60s penalty backoff");
}

ReconnectManager::State ReconnectManager::state() const noexcept
{
    return state_.load(std::memory_order_relaxed);
}

int ReconnectManager::computeBackoffMs(int attempts)
{
    static const int kDelays[] = {1000, 2000, 4000, 8000, 16000, 30000};
    const int idx = std::min(attempts, 5);
    return kDelays[idx];
}

void ReconnectManager::reconnectLoop()
{
    while (running_.load(std::memory_order_relaxed)) {
        {
            std::unique_lock<std::mutex> lock(reconnect_mutex_);
            reconnect_cv_.wait(lock, [this] {
                return should_reconnect_.load() || !running_.load();
            });
            if (!running_.load(std::memory_order_relaxed)) {
                break;
            }
            should_reconnect_.store(false, std::memory_order_relaxed);
        }

        int delay_ms;
        if (auth_failure_pending_) {
            auth_failure_pending_ = false;
            delay_ms = 60000;
            reconnect_attempts_ = 0;
        } else {
            delay_ms = computeBackoffMs(reconnect_attempts_);
            ++reconnect_attempts_;
        }

        std::uniform_real_distribution<double> jitter(0.9, 1.1);
        delay_ms = static_cast<int>(delay_ms * jitter(rng_));

        int elapsed = 0;
        while (elapsed < delay_ms && running_.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            elapsed += 100;
        }

        if (!running_.load(std::memory_order_relaxed)) {
            break;
        }

        state_.store(State::CONNECTING, std::memory_order_release);
        ROS_INFO("mavlink_quic_relay: attempting reconnect (attempt %d, delay was %dms)",
                 reconnect_attempts_, delay_ms);
        if (!quic_client_.connect())
        {
            ROS_WARN("mavlink_quic_relay: connect() failed, will retry");
        }
    }

    ROS_INFO("mavlink_quic_relay: reconnect thread exited");
}

}
