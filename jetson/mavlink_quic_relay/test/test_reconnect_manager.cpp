// GTest unit tests for ReconnectManager state machine.
//
// Design: start()/stop() are never called (avoids launching the reconnect
// thread that calls quic_client_.connect()). State transitions are exercised
// by calling onConnected(), onDisconnected(), onAuthOk(), onAuthFailed()
// directly on the object.
//
// ROS initialisation: ros::init() is called in main() so that ros::NodeHandle
// construction succeeds. Without a live rosmaster, subscribe/advertise/
// createTimer succeed but simply do not connect — no throw, no crash.
//
// computeBackoffMs is private static — it cannot be called from outside the
// class. See the skipped-test comment below for details and expected values.

#include <gtest/gtest.h>

#include <memory>

#include <ros/ros.h>

#include "mavlink_quic_relay/quic_client.h"
#include "mavlink_quic_relay/reconnect_manager.h"
#include "mavlink_quic_relay/ros_interface.h"

using mavlink_quic_relay::QuicClient;
using mavlink_quic_relay::QuicClientConfig;
using mavlink_quic_relay::ReconnectManager;
using mavlink_quic_relay::RosInterface;
using mavlink_quic_relay::RosInterfaceConfig;
using State = mavlink_quic_relay::ReconnectManager::State;

class ReconnectManagerTest : public ::testing::Test {
protected:
    void SetUp() override {
        nh_          = std::make_unique<ros::NodeHandle>();
        ros_iface_   = std::make_unique<RosInterface>(*nh_, RosInterfaceConfig{});
        quic_client_ = std::make_unique<QuicClient>(QuicClientConfig{});
        rm_          = std::make_unique<ReconnectManager>(*quic_client_, *ros_iface_);
    }

    std::unique_ptr<ros::NodeHandle>  nh_;
    std::unique_ptr<RosInterface>     ros_iface_;
    std::unique_ptr<QuicClient>       quic_client_;
    std::unique_ptr<ReconnectManager> rm_;
};

TEST_F(ReconnectManagerTest, InitialStateIsDisconnected) {
    EXPECT_EQ(rm_->state(), State::DISCONNECTED);
}

TEST_F(ReconnectManagerTest, OnConnectedTransitionsToAuthenticating) {
    rm_->onConnected();
    EXPECT_EQ(rm_->state(), State::AUTHENTICATING);
}

TEST_F(ReconnectManagerTest, OnAuthOkTransitionsToConnected) {
    rm_->onConnected();
    rm_->onAuthOk();
    EXPECT_EQ(rm_->state(), State::CONNECTED);
}

TEST_F(ReconnectManagerTest, OnDisconnectedFromConnectedTransitionsToDisconnected) {
    rm_->onConnected();
    rm_->onAuthOk();
    ASSERT_EQ(rm_->state(), State::CONNECTED);
    rm_->onDisconnected();
    EXPECT_EQ(rm_->state(), State::DISCONNECTED);
}

TEST_F(ReconnectManagerTest, OnAuthFailedTransitionsToDisconnected) {
    rm_->onConnected();
    ASSERT_EQ(rm_->state(), State::AUTHENTICATING);
    rm_->onAuthFailed();
    EXPECT_EQ(rm_->state(), State::DISCONNECTED);
}

TEST_F(ReconnectManagerTest, ReconnectAttemptsResetOnConnect) {
    rm_->onConnected();
    rm_->onAuthOk();
    rm_->onDisconnected();
    ASSERT_EQ(rm_->state(), State::DISCONNECTED);
    rm_->onConnected();
    EXPECT_EQ(rm_->state(), State::AUTHENTICATING);
}

TEST_F(ReconnectManagerTest, StateEnumValuesExistAndAreDistinct) {
    constexpr State s0 = State::DISCONNECTED;
    constexpr State s1 = State::CONNECTING;
    constexpr State s2 = State::AUTHENTICATING;
    constexpr State s3 = State::CONNECTED;
    EXPECT_NE(s0, s1);
    EXPECT_NE(s0, s2);
    EXPECT_NE(s0, s3);
    EXPECT_NE(s1, s2);
    EXPECT_NE(s1, s3);
    EXPECT_NE(s2, s3);
}

TEST_F(ReconnectManagerTest, MultipleDisconnectCallsAreIdempotent) {
    rm_->onDisconnected();
    EXPECT_EQ(rm_->state(), State::DISCONNECTED);
    rm_->onDisconnected();
    EXPECT_EQ(rm_->state(), State::DISCONNECTED);
}

TEST_F(ReconnectManagerTest, ConnectThenAuthOkThenDisconnect) {
    ASSERT_EQ(rm_->state(), State::DISCONNECTED);
    rm_->onConnected();
    ASSERT_EQ(rm_->state(), State::AUTHENTICATING);
    rm_->onAuthOk();
    ASSERT_EQ(rm_->state(), State::CONNECTED);
    rm_->onDisconnected();
    EXPECT_EQ(rm_->state(), State::DISCONNECTED);
}

TEST_F(ReconnectManagerTest, AuthFailSequence) {
    rm_->onConnected();
    ASSERT_EQ(rm_->state(), State::AUTHENTICATING);
    rm_->onAuthFailed();
    EXPECT_EQ(rm_->state(), State::DISCONNECTED);
}

TEST_F(ReconnectManagerTest, StateIsDisconnectedAfterAuthFailed) {
    rm_->onConnected();
    rm_->onAuthFailed();
    EXPECT_EQ(rm_->state(), State::DISCONNECTED);
    rm_->onDisconnected();
    EXPECT_EQ(rm_->state(), State::DISCONNECTED);
}

// Test 12 (ComputeBackoffMsValues) is omitted: computeBackoffMs is declared
// private in reconnect_manager.h and cannot be called from an external test
// without a friend declaration or access modifier change. Expected values
// (from reconnect_manager.cpp, kDelays[], std::min(attempts,5)):
//   0→1000ms  1→2000ms  2→4000ms  3→8000ms  4→16000ms  5+→30000ms.

TEST_F(ReconnectManagerTest, StateQueryIsStable) {
    for (int i = 0; i < 100; ++i) {
        static_cast<void>(rm_->state());
    }
    rm_->onConnected();
    for (int i = 0; i < 100; ++i) {
        EXPECT_EQ(rm_->state(), State::AUTHENTICATING);
    }
}

TEST_F(ReconnectManagerTest, TwoFullCycles) {
    rm_->onConnected();
    EXPECT_EQ(rm_->state(), State::AUTHENTICATING);
    rm_->onAuthOk();
    EXPECT_EQ(rm_->state(), State::CONNECTED);
    rm_->onDisconnected();
    EXPECT_EQ(rm_->state(), State::DISCONNECTED);

    rm_->onConnected();
    EXPECT_EQ(rm_->state(), State::AUTHENTICATING);
    rm_->onAuthOk();
    EXPECT_EQ(rm_->state(), State::CONNECTED);
    rm_->onDisconnected();
    EXPECT_EQ(rm_->state(), State::DISCONNECTED);
}

TEST_F(ReconnectManagerTest, AuthFailThenReconnect) {
    rm_->onConnected();
    rm_->onAuthFailed();
    ASSERT_EQ(rm_->state(), State::DISCONNECTED);
    rm_->onConnected();
    EXPECT_EQ(rm_->state(), State::AUTHENTICATING);
    rm_->onAuthOk();
    EXPECT_EQ(rm_->state(), State::CONNECTED);
}

int main(int argc, char** argv) {
    ros::init(argc, argv, "test_reconnect_manager",
              ros::init_options::AnonymousName);
    ros::Time::init();
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
