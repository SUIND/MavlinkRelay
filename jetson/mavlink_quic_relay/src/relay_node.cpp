#include "mavlink_quic_relay/relay_node.h"

#include <ros/ros.h>

#include <chrono>
#include <thread>

namespace mavlink_quic_relay
{

RelayNode::RelayNode(ros::NodeHandle& nh, RelayNodeConfig config) : config_(std::move(config)), nh_(nh)
{
  classifier_ = std::make_unique<PriorityClassifier>();
  ros_interface_ = std::make_unique<RosInterface>(nh_, config_.ros);
  quic_client_ = std::make_unique<QuicClient>(config_.quic);

  quic_client_->setFrameReceivedCallback([this](std::vector<uint8_t> frame) { onFrameReceived(std::move(frame)); });

  quic_client_->setConnectionStateCallback([this](bool connected) { onConnectionStateChanged(connected); });

  reconnect_manager_ = std::make_unique<ReconnectManager>(*quic_client_, *ros_interface_);

  quic_client_->setAuthOkCallback([this] { onAuthOk(); });
  quic_client_->setAuthFailCallback([this] { onAuthFailed(); });

  quic_event_timer_ = nh_.createTimer(ros::Duration(0.001), &RelayNode::quicEventCallback, this);
}

RelayNode::~RelayNode() { stop(); }

void RelayNode::start()
{
  running_.store(true, std::memory_order_relaxed);

  const bool ok = quic_client_->connect();
  if (!ok)
  {
    ROS_WARN("mavlink_quic_relay: connect() returned false — will retry when connection events arrive");
  }

  reconnect_manager_->start();

  sender_thread_ = std::thread(&RelayNode::senderLoop, this);

  ROS_INFO("mavlink_quic_relay: relay started, connecting to %s:%d", config_.quic.server_host.c_str(),
           static_cast<int>(config_.quic.server_port));
}

void RelayNode::stop()
{
  if (!running_.load(std::memory_order_relaxed) && !sender_thread_.joinable())
  {
    return;
  }

  ROS_INFO("mavlink_quic_relay: stopping");

  running_.store(false, std::memory_order_relaxed);

  quic_event_timer_.stop();
  reconnect_manager_->stop();
  quic_client_->shutdown();

  if (sender_thread_.joinable())
  {
    sender_thread_.join();
  }

  ROS_INFO("mavlink_quic_relay: stopped cleanly");
}

void RelayNode::senderLoop()
{
  ROS_INFO("mavlink_quic_relay: sender thread started");

  while (running_.load(std::memory_order_relaxed))
  {
    bool sent_anything = false;

    while (true)
    {
      auto frame = ros_interface_->popOutbound();
      if (!frame)
      {
        break;
      }

      if (!quic_client_->isConnected())
      {
        break;
      }

      if (classifier_->classify(frame->msgid) == StreamType::PRIORITY)
      {
        if (!quic_client_->sendPriorityFrame(frame->raw_bytes))
        {
          ROS_WARN_THROTTLE(5.0, "Priority frame send failed (msgid=%u)", frame->msgid);
        }
      }
      else
      {
        if (!quic_client_->sendBulkFrame(frame->raw_bytes))
        {
          ROS_WARN_THROTTLE(5.0, "Bulk frame send failed (msgid=%u)", frame->msgid);
        }
      }
      sent_anything = true;
    }

    if (!sent_anything)
    {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }

  ROS_INFO("mavlink_quic_relay: sender thread exited");
}

void RelayNode::quicEventCallback(const ros::TimerEvent& /*event*/) { quic_client_->processEvents(); }

void RelayNode::onConnectionStateChanged(bool connected)
{
  if (connected)
  {
    reconnect_manager_->onConnected();
  }
  else
  {
    if (running_.load(std::memory_order_relaxed))
    {
      reconnect_manager_->onDisconnected();
    }
    else
    {
      ROS_INFO("mavlink_quic_relay: QUIC disconnected during shutdown");
    }
  }
}

void RelayNode::onAuthOk() { reconnect_manager_->onAuthOk(); }

void RelayNode::onAuthFailed() { reconnect_manager_->onAuthFailed(); }

void RelayNode::onFrameReceived(std::vector<uint8_t> frame)
{
  // Extract msgid for completeness; MAVLink v2: bytes [7..9] are msgid (24-bit LE)
  // MAVLink v1: byte [5] is msgid (8-bit). Use 0 as safe fallback if frame is too short.
  uint32_t msgid = 0;
  if (frame.size() >= 8U)
  {
    if (frame[0] == 0xFDU)
    {
      // MAVLink v2
      msgid = static_cast<uint32_t>(frame[7]) | (static_cast<uint32_t>(frame[8]) << 8U) |
              (static_cast<uint32_t>(frame[9]) << 16U);
    }
    else if (frame[0] == 0xFEU && frame.size() >= 6U)
    {
      // MAVLink v1
      msgid = static_cast<uint32_t>(frame[5]);
    }
  }

  ros_interface_->pushInbound(MavlinkFrame{msgid, std::move(frame)});
}

RelayNodeConfig loadRelayNodeConfig(ros::NodeHandle& nh)
{
  RelayNodeConfig cfg;

  nh.param<std::string>("server_host", cfg.quic.server_host, "");

  int server_port = 5000;
  nh.param<int>("server_port", server_port, 5000);
  cfg.quic.server_port = static_cast<uint16_t>(server_port);

  nh.param<std::string>("auth_token", cfg.quic.auth_token, "");

  nh.param<std::string>("vehicle_id", cfg.quic.vehicle_id, "BB_000001");

  nh.param<std::string>("ca_cert_path", cfg.quic.ca_cert_path, "");
  nh.param<std::string>("alpn", cfg.quic.alpn, "mavlink-quic-v1");

  int keepalive_ms = 15000;
  nh.param<int>("keepalive_interval_ms", keepalive_ms, 15000);
  cfg.quic.keepalive_interval_ms = static_cast<uint32_t>(keepalive_ms);

  int idle_ms = 60000;
  nh.param<int>("idle_timeout_ms", idle_ms, 60000);
  cfg.quic.idle_timeout_ms = static_cast<uint32_t>(idle_ms);

  nh.param<std::string>("mavlink_from_topic", cfg.ros.mavlink_from_topic, "/mavlink/from");
  nh.param<std::string>("mavlink_to_topic", cfg.ros.mavlink_to_topic, "/mavlink/to");

  int pq_size = 100;
  nh.param<int>("priority_queue_size", pq_size, 100);
  cfg.priority_queue_size = static_cast<std::size_t>(pq_size);

  int bq_size = 500;
  nh.param<int>("bulk_queue_size", bq_size, 500);
  cfg.bulk_queue_size = static_cast<std::size_t>(bq_size);

  cfg.ros.outbound_queue_max = cfg.bulk_queue_size;
  cfg.ros.inbound_queue_max = 500;

  double warn_timeout = 10.0;
  nh.param<double>("no_message_warn_timeout_s", warn_timeout, 10.0);
  cfg.ros.no_message_warn_timeout_s = warn_timeout;

  return cfg;
}

}  // namespace mavlink_quic_relay
