#include <ros/ros.h>

#include "mavlink_quic_relay/relay_node.h"

int main(int argc, char** argv)
{
    ros::init(argc, argv, "mavlink_quic_relay");

    ros::NodeHandle nh("~");

    std::string auth_token;
    nh.param<std::string>("auth_token", auth_token, "CHANGE_ME");
    if (auth_token == "CHANGE_ME" || auth_token.empty()) {
        ROS_FATAL("auth_token is not set or is still 'CHANGE_ME'. "
                  "Set a valid token in config/relay_params.yaml before running.");
        ros::shutdown();
        return 1;
    }

    std::string server_host;
    nh.param<std::string>("server_host", server_host, "");
    if (server_host.empty()) {
        ROS_FATAL("server_host is not set. Configure it in relay_params.yaml.");
        ros::shutdown();
        return 1;
    }

    ROS_INFO("mavlink_quic_relay node initialized");

    ros::AsyncSpinner spinner(4);
    spinner.start();

    auto relay_config = mavlink_quic_relay::loadRelayNodeConfig(nh);
    mavlink_quic_relay::RelayNode relay(nh, relay_config);
    relay.start();

    ros::waitForShutdown();

    relay.stop();

    ROS_INFO("mavlink_quic_relay node shutting down");

    return 0;
}
