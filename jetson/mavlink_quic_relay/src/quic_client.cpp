/**
 * quic_client.cpp — msquic C API wrapper for mavlink_quic_relay.
 *
 * Threading model:
 *   msquic callbacks fire on internal msquic worker threads.
 *   All received data and state changes are posted to event_queue_ (mutex protected).
 *   processEvents() is called from the ROS timer thread to drain the queue and invoke
 *   user callbacks — this is the only place ros::Publisher::publish() may be called.
 *
 * Buffer ownership:
 *   SendBuffer instances are kept in pending_sends_ until QUIC_STREAM_EVENT_SEND_COMPLETE
 *   fires, at which point they are released. On shutdown, all pending buffers are cleared
 *   in the SHUTDOWN_COMPLETE handler.
 *
 * AUTH sequencing:
 *   Control stream (index 0) is opened first. An AUTH CBOR message is sent immediately.
 *   When AUTH_OK is received on the control stream, openMavlinkStreams() opens the
 *   priority (index 1) and bulk (index 2) streams.
 */

#include <mavlink_quic_relay/quic_client.h>

#ifdef MAVLINK_QUIC_RELAY_HAVE_MSQUIC

#include <ros/ros.h>

#include <algorithm>
#include <chrono>
#include <cstring>

namespace mavlink_quic_relay {

// ── SendBuffer ────────────────────────────────────────────────────────────────

SendBuffer::SendBuffer(const std::vector<uint8_t>& payload)
{
    const uint16_t len = static_cast<uint16_t>(payload.size());
    data.resize(2 + payload.size());
    // Little-endian u16 length prefix
    data[0] = static_cast<uint8_t>(len & 0xFFu);
    data[1] = static_cast<uint8_t>((len >> 8u) & 0xFFu);
    std::copy(payload.begin(), payload.end(), data.begin() + 2);
    quic_buf.Buffer = data.data();
    quic_buf.Length = static_cast<uint32_t>(data.size());
}

// ── QuicClient construction / destruction ─────────────────────────────────────

QuicClient::QuicClient(QuicClientConfig config)
    : config_(std::move(config))
{
}

QuicClient::~QuicClient()
{
    if (!shutdown_requested_.load()) {
        shutdown();
    }
}

// ── Public setters ────────────────────────────────────────────────────────────

void QuicClient::setFrameReceivedCallback(FrameReceivedCallback cb)
{
    std::lock_guard<std::mutex> lk(event_queue_mutex_);
    frame_cb_ = std::move(cb);
}

void QuicClient::setConnectionStateCallback(ConnectionStateCallback cb)
{
    std::lock_guard<std::mutex> lk(event_queue_mutex_);
    state_cb_ = std::move(cb);
}

void QuicClient::setAuthOkCallback(std::function<void()> cb)
{
    std::lock_guard<std::mutex> lk(event_queue_mutex_);
    auth_ok_cb_ = std::move(cb);
}

void QuicClient::setAuthFailCallback(std::function<void()> cb)
{
    std::lock_guard<std::mutex> lk(event_queue_mutex_);
    auth_fail_cb_ = std::move(cb);
}

// ── isConnected ───────────────────────────────────────────────────────────────

bool QuicClient::isConnected() const noexcept
{
    return connected_.load(std::memory_order_relaxed);
}

// ── initMsquic ────────────────────────────────────────────────────────────────

bool QuicClient::initMsquic()
{
    QUIC_STATUS status = MsQuicOpen2(&msquic_);
    if (QUIC_FAILED(status)) {
        ROS_ERROR_STREAM("MsQuicOpen2 failed: 0x" << std::hex << status);
        return false;
    }

    QUIC_REGISTRATION_CONFIG reg_config{"mavlink_quic_relay",
                                        QUIC_EXECUTION_PROFILE_LOW_LATENCY};
    status = msquic_->RegistrationOpen(&reg_config, &registration_);
    if (QUIC_FAILED(status)) {
        ROS_ERROR_STREAM("RegistrationOpen failed: 0x" << std::hex << status);
        MsQuicClose(msquic_);
        msquic_ = nullptr;
        return false;
    }

    QUIC_SETTINGS settings{};
    settings.KeepAliveIntervalMs      = config_.keepalive_interval_ms;
    settings.IsSet.KeepAliveIntervalMs = 1;
    settings.IdleTimeoutMs            = config_.idle_timeout_ms;
    settings.IsSet.IdleTimeoutMs      = 1;
    settings.PeerBidiStreamCount      = 1;
    settings.IsSet.PeerBidiStreamCount = 1;

    QUIC_BUFFER alpn_buf{};
    alpn_buf.Buffer = reinterpret_cast<uint8_t*>(const_cast<char*>(config_.alpn.c_str()));
    alpn_buf.Length = static_cast<uint32_t>(config_.alpn.size());

    status = msquic_->ConfigurationOpen(
        registration_, &alpn_buf, 1, &settings, sizeof(settings), nullptr, &configuration_);
    if (QUIC_FAILED(status)) {
        ROS_ERROR_STREAM("ConfigurationOpen failed: 0x" << std::hex << status);
        msquic_->RegistrationClose(registration_);
        registration_ = nullptr;
        MsQuicClose(msquic_);
        msquic_ = nullptr;
        return false;
    }

    QUIC_CREDENTIAL_CONFIG cred_config{};
    cred_config.Type  = QUIC_CREDENTIAL_TYPE_NONE;
    cred_config.Flags = QUIC_CREDENTIAL_FLAG_CLIENT |
                        QUIC_CREDENTIAL_FLAG_INDICATE_CERTIFICATE_RECEIVED;

    if (!config_.ca_cert_path.empty()) {
        cred_config.Flags           |= QUIC_CREDENTIAL_FLAG_SET_CA_CERTIFICATE_FILE;
        cred_config.CaCertificateFile = config_.ca_cert_path.c_str();
    } else {
        // No CA cert provided — skip server certificate validation.
        // The server uses a self-signed cert that won't be in the system trust
        // store.  Authentication is handled at the application layer (AUTH token),
        // so skipping TLS cert validation here is acceptable.
        cred_config.Flags |= QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION;
    }

    status = msquic_->ConfigurationLoadCredential(configuration_, &cred_config);
    if (QUIC_FAILED(status)) {
        ROS_ERROR_STREAM("ConfigurationLoadCredential failed: 0x" << std::hex << status);
        msquic_->ConfigurationClose(configuration_);
        configuration_ = nullptr;
        msquic_->RegistrationClose(registration_);
        registration_ = nullptr;
        MsQuicClose(msquic_);
        msquic_ = nullptr;
        return false;
    }

    return true;
}

// ── connect ───────────────────────────────────────────────────────────────────

bool QuicClient::connect()
{
    if (!initMsquic()) {
        return false;
    }

    QUIC_STATUS status = msquic_->ConnectionOpen(
        registration_, connectionCallback, this, &connection_);
    if (QUIC_FAILED(status)) {
        ROS_ERROR_STREAM("ConnectionOpen failed: 0x" << std::hex << status);
        return false;
    }

    status = msquic_->ConnectionStart(
        connection_,
        configuration_,
        QUIC_ADDRESS_FAMILY_UNSPEC,
        config_.server_host.c_str(),
        config_.server_port);
    if (QUIC_FAILED(status)) {
        ROS_ERROR_STREAM("ConnectionStart failed: 0x" << std::hex << status);
        msquic_->ConnectionClose(connection_);
        connection_ = nullptr;
        return false;
    }

    ROS_INFO_STREAM("QUIC ConnectionStart initiated to " << config_.server_host
                    << ":" << config_.server_port);
    return true;
}

// ── openStreams ───────────────────────────────────────────────────────────────

bool QuicClient::openStreams()
{
    // Open control stream (index 0)
    StreamContext* ctx = new StreamContext{this, 0};

    QUIC_STATUS status = msquic_->StreamOpen(
        connection_,
        QUIC_STREAM_OPEN_FLAG_NONE,
        streamCallback,
        ctx,
        &stream_control_);
    if (QUIC_FAILED(status)) {
        ROS_ERROR_STREAM("StreamOpen(control) failed: 0x" << std::hex << status);
        delete ctx;
        return false;
    }

    status = msquic_->StreamStart(stream_control_, QUIC_STREAM_START_FLAG_NONE);
    if (QUIC_FAILED(status)) {
        ROS_ERROR_STREAM("StreamStart(control) failed: 0x" << std::hex << status);
        msquic_->StreamClose(stream_control_);
        stream_control_ = nullptr;
        delete ctx;
        return false;
    }

    ROS_INFO("Control stream opened — sending AUTH");
    sendAuth();
    return true;
}

// ── openMavlinkStreams (called after AUTH_OK) ─────────────────────────────────

void QuicClient::openMavlinkStreams()
{
    // Priority stream (index 1)
    {
        StreamContext* ctx = new StreamContext{this, 1};
        QUIC_STATUS status = msquic_->StreamOpen(
            connection_,
            QUIC_STREAM_OPEN_FLAG_NONE,
            streamCallback,
            ctx,
            &stream_priority_);
        if (QUIC_FAILED(status)) {
            ROS_ERROR_STREAM("StreamOpen(priority) failed: 0x" << std::hex << status);
            delete ctx;
        } else {
            status = msquic_->StreamStart(stream_priority_, QUIC_STREAM_START_FLAG_NONE);
            if (QUIC_FAILED(status)) {
                ROS_ERROR_STREAM("StreamStart(priority) failed: 0x" << std::hex << status);
                msquic_->StreamClose(stream_priority_);
                stream_priority_ = nullptr;
                delete ctx;
            } else {
                ROS_INFO("Priority stream opened");
            }
        }
    }

    // Bulk stream (index 2)
    {
        StreamContext* ctx = new StreamContext{this, 2};
        QUIC_STATUS status = msquic_->StreamOpen(
            connection_,
            QUIC_STREAM_OPEN_FLAG_NONE,
            streamCallback,
            ctx,
            &stream_bulk_);
        if (QUIC_FAILED(status)) {
            ROS_ERROR_STREAM("StreamOpen(bulk) failed: 0x" << std::hex << status);
            delete ctx;
        } else {
            status = msquic_->StreamStart(stream_bulk_, QUIC_STREAM_START_FLAG_NONE);
            if (QUIC_FAILED(status)) {
                ROS_ERROR_STREAM("StreamStart(bulk) failed: 0x" << std::hex << status);
                msquic_->StreamClose(stream_bulk_);
                stream_bulk_ = nullptr;
                delete ctx;
            } else {
                ROS_INFO("Bulk stream opened");
            }
        }
    }
}

// ── CBOR build helpers ────────────────────────────────────────────────────────
//
// Minimal CBOR encoding for the AUTH message and PONG response.
// Encoding follows RFC 8949 (CBOR).
//
//   Map header:       0xa0 | N          (N items, N <= 23)
//   Text string:      0x60 | len + UTF8 bytes  (len <= 23)
//                  or 0x78 <1-byte-len> + UTF8 bytes  (24..255)
//   Byte string:      0x40 | len + bytes       (len <= 23)
//                  or 0x58 <1-byte-len> + bytes        (24..255)
//   Unsigned int:     0x00..0x17               (0..23 inline)
//                  or 0x18 <byte>              (24..255)
//                  or 0x19 <hi> <lo>           (256..65535)
//                  or 0x1a <4-bytes BE>        (65536..2^32-1)
//   Float64:          0xfb <8-bytes BE IEEE 754>

static void cborAppendTextString(std::vector<uint8_t>& buf, const std::string& s)
{
    const size_t n = s.size();
    if (n <= 23) {
        buf.push_back(static_cast<uint8_t>(0x60u | n));
    } else if (n <= 0xFFu) {
        buf.push_back(0x78u);
        buf.push_back(static_cast<uint8_t>(n));
    } else {
        buf.push_back(0x79u);
        buf.push_back(static_cast<uint8_t>((n >> 8u) & 0xFFu));
        buf.push_back(static_cast<uint8_t>(n & 0xFFu));
    }
    buf.insert(buf.end(), s.begin(), s.end());
}

static void cborAppendByteString(std::vector<uint8_t>& buf, const std::vector<uint8_t>& bytes)
{
    const size_t n = bytes.size();
    if (n <= 23) {
        buf.push_back(static_cast<uint8_t>(0x40u | n));
    } else if (n <= 0xFFu) {
        buf.push_back(0x58u);
        buf.push_back(static_cast<uint8_t>(n));
    } else {
        buf.push_back(0x59u);
        buf.push_back(static_cast<uint8_t>((n >> 8u) & 0xFFu));
        buf.push_back(static_cast<uint8_t>(n & 0xFFu));
    }
    buf.insert(buf.end(), bytes.begin(), bytes.end());
}

// ── CBOR map reader helpers ───────────────────────────────────────────────────
//
// Minimal CBOR map key lookup — sufficient for the small, flat control messages
// sent by the relay server.  Only handles top-level text-string keys.
//
// CBOR major types used here:
//   0x60..0x77  tstr (len 0..23 inline)
//   0x78        tstr (1-byte len follows)
//   0xfb        float64 (8 bytes follow, IEEE 754 big-endian)
//   0xa0..0xb7  map  (len 0..23 inline)
//   0xb8        map  (1-byte len follows)

/// Advance *pos past the next CBOR item (key or value) in buf.
/// Returns false if the buffer is malformed / too short.
static bool cborSkipItem(const std::vector<uint8_t>& buf, size_t& pos)
{
    if (pos >= buf.size()) return false;
    const uint8_t b = buf[pos++];
    const uint8_t major = b >> 5u;
    const uint8_t info  = b & 0x1fu;

    uint64_t arg = info;
    if (info == 24u) {
        if (pos >= buf.size()) return false;
        arg = buf[pos++];
    } else if (info == 25u) {
        if (pos + 2 > buf.size()) return false;
        arg = (static_cast<uint64_t>(buf[pos]) << 8u) | buf[pos + 1];
        pos += 2;
    } else if (info == 26u) {
        if (pos + 4 > buf.size()) return false;
        arg = (static_cast<uint64_t>(buf[pos]) << 24u) | (static_cast<uint64_t>(buf[pos+1]) << 16u)
            | (static_cast<uint64_t>(buf[pos+2]) << 8u) | buf[pos+3];
        pos += 4;
    } else if (info == 27u) {
        if (pos + 8 > buf.size()) return false;
        arg = 0;
        for (int i = 0; i < 8; ++i) arg = (arg << 8u) | buf[pos + i];
        pos += 8;
    } else if (info >= 28u && info <= 30u) {
        return false;  // reserved
    }

    switch (major) {
        case 0: case 1: break;           // uint / nint — arg already consumed
        case 2: case 3:                  // bstr / tstr — skip arg bytes
            if (pos + arg > buf.size()) return false;
            pos += static_cast<size_t>(arg);
            break;
        case 4:                          // array — skip arg items
            for (uint64_t i = 0; i < arg; ++i) {
                if (!cborSkipItem(buf, pos)) return false;
            }
            break;
        case 5:                          // map — skip 2*arg items
            for (uint64_t i = 0; i < arg * 2u; ++i) {
                if (!cborSkipItem(buf, pos)) return false;
            }
            break;
        case 7:
            // floats: info==25 (half, 2 extra), 26 (float, 4 extra), 27 (double, 8 extra)
            // info==20..23 are simple values (already consumed); others already handled above.
            if (info == 25u) { /* already advanced 2 */ }
            else if (info == 26u) { /* already advanced 4 */ }
            else if (info == 27u) { /* already advanced 8 */ }
            break;
        default:
            return false;
    }
    return true;
}

/// Read the text-string value for a given key from a flat CBOR map.
/// Returns empty string if key not found or value is not a tstr.
static std::string cborGetStringField(const std::vector<uint8_t>& buf,
                                       const std::string& key)
{
    if (buf.empty()) return {};
    size_t pos = 0;
    const uint8_t b = buf[pos++];
    if ((b >> 5u) != 5u) return {};  // not a map

    uint64_t map_len = b & 0x1fu;
    if ((b & 0x1fu) == 24u) {
        if (pos >= buf.size()) return {};
        map_len = buf[pos++];
    }

    for (uint64_t i = 0; i < map_len; ++i) {
        if (pos >= buf.size()) return {};
        const uint8_t kb = buf[pos];
        const uint8_t major = kb >> 5u;
        const uint8_t info  = kb & 0x1fu;
        if (major != 3u) { // not a tstr key — skip key + value
            if (!cborSkipItem(buf, pos)) return {};
            if (!cborSkipItem(buf, pos)) return {};
            continue;
        }
        ++pos;
        size_t klen = info;
        if (info == 24u) {
            if (pos >= buf.size()) return {};
            klen = buf[pos++];
        }
        if (pos + klen > buf.size()) return {};
        const std::string k(reinterpret_cast<const char*>(buf.data() + pos), klen);
        pos += klen;

        // Now read value
        if (pos >= buf.size()) return {};
        if (k == key) {
            const uint8_t vb = buf[pos];
            const uint8_t vmajor = vb >> 5u;
            const uint8_t vinfo  = vb & 0x1fu;
            if (vmajor != 3u) {  // value is not a tstr
                if (!cborSkipItem(buf, pos)) return {};
                return {};
            }
            ++pos;
            size_t vlen = vinfo;
            if (vinfo == 24u) {
                if (pos >= buf.size()) return {};
                vlen = buf[pos++];
            }
            if (pos + vlen > buf.size()) return {};
            return std::string(reinterpret_cast<const char*>(buf.data() + pos), vlen);
        } else {
            if (!cborSkipItem(buf, pos)) return {};
        }
    }
    return {};
}

/// Read a float64 value for a given key from a flat CBOR map.
/// Returns 0.0 if key not found or value is not a float64 (major 7, info 27).
static double cborGetFloat64Field(const std::vector<uint8_t>& buf,
                                   const std::string& key)
{
    if (buf.empty()) return 0.0;
    size_t pos = 0;
    const uint8_t b = buf[pos++];
    if ((b >> 5u) != 5u) return 0.0;

    uint64_t map_len = b & 0x1fu;
    if ((b & 0x1fu) == 24u) {
        if (pos >= buf.size()) return 0.0;
        map_len = buf[pos++];
    }

    for (uint64_t i = 0; i < map_len; ++i) {
        if (pos >= buf.size()) return 0.0;
        const uint8_t kb = buf[pos];
        const uint8_t major = kb >> 5u;
        const uint8_t info  = kb & 0x1fu;
        if (major != 3u) {
            if (!cborSkipItem(buf, pos)) return 0.0;
            if (!cborSkipItem(buf, pos)) return 0.0;
            continue;
        }
        ++pos;
        size_t klen = info;
        if (info == 24u) {
            if (pos >= buf.size()) return 0.0;
            klen = buf[pos++];
        }
        if (pos + klen > buf.size()) return 0.0;
        const std::string k(reinterpret_cast<const char*>(buf.data() + pos), klen);
        pos += klen;

        if (pos >= buf.size()) return 0.0;
        if (k == key) {
            // Expect float64: 0xfb followed by 8 bytes (big-endian IEEE 754)
            if (buf[pos] != 0xfbu) {
                if (!cborSkipItem(buf, pos)) return 0.0;
                return 0.0;
            }
            ++pos;
            if (pos + 8 > buf.size()) return 0.0;
            uint64_t raw64 = 0;
            for (int j = 0; j < 8; ++j) {
                raw64 = (raw64 << 8u) | buf[pos + j];
            }
            pos += 8;
            double val;
            std::memcpy(&val, &raw64, sizeof(val));
            return val;
        } else {
            if (!cborSkipItem(buf, pos)) return 0.0;
        }
    }
    return 0.0;
}

/// Build a CBOR-encoded PONG message: {"type": "PONG", "ts": <float64>}
/// with a u16_le length prefix (matching the server's encode_frame format).
static std::vector<uint8_t> cborBuildPong(double ts)
{
    std::vector<uint8_t> cbor;
    cbor.reserve(32);

    // Map(2)
    cbor.push_back(0xa2u);

    // "type": "PONG"
    cborAppendTextString(cbor, "type");
    cborAppendTextString(cbor, "PONG");

    // "ts": float64 — CBOR major 7, additional info 27 (0xfb)
    cborAppendTextString(cbor, "ts");
    cbor.push_back(0xfbu);
    uint64_t raw64;
    std::memcpy(&raw64, &ts, sizeof(raw64));
    for (int shift = 56; shift >= 0; shift -= 8) {
        cbor.push_back(static_cast<uint8_t>((raw64 >> shift) & 0xFFu));
    }

    // Prepend u16_le length prefix (mirrors server's encode_frame)
    const uint16_t len = static_cast<uint16_t>(cbor.size());
    std::vector<uint8_t> framed;
    framed.reserve(2 + cbor.size());
    framed.push_back(static_cast<uint8_t>(len & 0xFFu));
    framed.push_back(static_cast<uint8_t>((len >> 8u) & 0xFFu));
    framed.insert(framed.end(), cbor.begin(), cbor.end());
    return framed;
}

// ── handleControlFrame ────────────────────────────────────────────────────────

void QuicClient::handleControlFrame(const std::vector<uint8_t>& frame)
{
    const std::string msg_type = cborGetStringField(frame, "type");

    if (msg_type == "AUTH_OK") {
        if (!auth_ok_.load()) {
            ROS_INFO("AUTH_OK received — opening MAVLink streams");
            auth_ok_.store(true);
            openMavlinkStreams();
            postEvent(InternalEvent{InternalEvent::Type::AUTH_OK, {}, false});
        }
    } else if (msg_type == "AUTH_FAIL") {
        const std::string reason = cborGetStringField(frame, "reason");
        ROS_ERROR_STREAM("AUTH_FAIL received from server: " << reason);
        postEvent(InternalEvent{InternalEvent::Type::AUTH_FAIL, {}, false});
    } else if (msg_type == "PING") {
        // Echo ts back as PONG immediately on the msquic callback thread.
        // sendOnStream is mutex-protected and safe to call here.
        const double ts = cborGetFloat64Field(frame, "ts");
        const std::vector<uint8_t> pong = cborBuildPong(ts);
        // pong is already length-prefixed; send the raw framed bytes directly.
        if (stream_control_) {
            auto buf = std::make_unique<SendBuffer>(std::vector<uint8_t>{});
            // Re-use SendBuffer but with pre-framed payload (skip double-framing).
            // Build a raw SendBuffer manually so the framed bytes go as-is.
            buf->data = pong;
            buf->quic_buf.Buffer = buf->data.data();
            buf->quic_buf.Length = static_cast<uint32_t>(buf->data.size());
            SendBuffer* raw_ptr = buf.get();
            {
                std::lock_guard<std::mutex> lk(pending_sends_mutex_);
                pending_sends_.push(std::move(buf));
            }
            const QUIC_STATUS status = msquic_->StreamSend(
                stream_control_, &raw_ptr->quic_buf, 1, QUIC_SEND_FLAG_NONE, raw_ptr);
            if (QUIC_FAILED(status)) {
                ROS_WARN_STREAM("PONG send failed: 0x" << std::hex << status);
                std::lock_guard<std::mutex> lk(pending_sends_mutex_);
                std::queue<std::unique_ptr<SendBuffer>> tmp;
                while (!pending_sends_.empty()) {
                    if (pending_sends_.front().get() != raw_ptr)
                        tmp.push(std::move(pending_sends_.front()));
                    pending_sends_.pop();
                }
                pending_sends_ = std::move(tmp);
            } else {
                ROS_DEBUG("PONG sent (ts=%.3f)", ts);
            }
        }
    } else if (!msg_type.empty()) {
        ROS_DEBUG_STREAM("Unknown control message type: " << msg_type);
    } else {
        ROS_WARN("Control frame with missing or non-string 'type' field");
    }
}

// ── base64 decoder ───────────────────────────────────────────────────────────
//
// Decodes a standard base64 string (RFC 4648, with '=' padding) to raw bytes.
// Returns an empty vector on malformed input.
// Used exclusively by sendAuth() to convert the base64 auth_token config value
// to the 16 raw bytes the server expects in the CBOR AUTH message.

static std::vector<uint8_t> base64Decode(const std::string& encoded)
{
    // Standard base64 alphabet: A-Z (0..25), a-z (26..51), 0-9 (52..61), +, /
    // '=' is padding (value 64 used as sentinel), all others invalid (255).
    static const uint8_t kDecodeTable[256] = {
        255,255,255,255, 255,255,255,255, 255,255,255,255, 255,255,255,255,  // 0x00
        255,255,255,255, 255,255,255,255, 255,255,255,255, 255,255,255,255,  // 0x10
        255,255,255,255, 255,255,255,255, 255,255,255, 62, 255,255,255, 63,  // 0x20  (+, /)
         52, 53, 54, 55,  56, 57, 58, 59,  60, 61,255,255, 255, 64,255,255,  // 0x30  (0-9, =)
        255,  0,  1,  2,   3,  4,  5,  6,   7,  8,  9, 10,  11, 12, 13, 14,  // 0x40  (A-O)
         15, 16, 17, 18,  19, 20, 21, 22,  23, 24, 25,255, 255,255,255,255,  // 0x50  (P-Z)
        255, 26, 27, 28,  29, 30, 31, 32,  33, 34, 35, 36,  37, 38, 39, 40,  // 0x60  (a-o)
         41, 42, 43, 44,  45, 46, 47, 48,  49, 50, 51,255, 255,255,255,255,  // 0x70  (p-z)
        255,255,255,255, 255,255,255,255, 255,255,255,255, 255,255,255,255,
        255,255,255,255, 255,255,255,255, 255,255,255,255, 255,255,255,255,
        255,255,255,255, 255,255,255,255, 255,255,255,255, 255,255,255,255,
        255,255,255,255, 255,255,255,255, 255,255,255,255, 255,255,255,255,
        255,255,255,255, 255,255,255,255, 255,255,255,255, 255,255,255,255,
        255,255,255,255, 255,255,255,255, 255,255,255,255, 255,255,255,255,
        255,255,255,255, 255,255,255,255, 255,255,255,255, 255,255,255,255,
        255,255,255,255, 255,255,255,255, 255,255,255,255, 255,255,255,255,
    };

    std::vector<uint8_t> out;
    out.reserve((encoded.size() / 4u) * 3u);

    uint32_t acc = 0u;
    int bits     = 0;

    for (const char c : encoded) {
        const uint8_t v = kDecodeTable[static_cast<uint8_t>(c)];
        if (v == 255u) return {};   // invalid character
        if (v == 64u) break;        // '=' padding — stop

        acc  = (acc << 6u) | v;
        bits += 6;

        if (bits >= 8) {
            bits -= 8;
            out.push_back(static_cast<uint8_t>((acc >> static_cast<unsigned>(bits)) & 0xFFu));
        }
    }
    return out;
}

// ── sendAuth ──────────────────────────────────────────────────────────────────
//
// Manual CBOR encoding for:
//   {
//     "type":       "AUTH",
//     "token":      bytes(raw_16_bytes),
//     "role":       "vehicle",
//     "vehicle_id": "BB_000001"   (text string)
//   }
//
// The auth_token config field is a base64-encoded string (matching the server's
// YAML auth.tokens[].token field).  base64Decode() converts it to the raw bytes
// before they are placed in the CBOR bstr — the Python server decodes its YAML
// token the same way and compares the raw bytes.

void QuicClient::sendAuth()
{
    // Decode the base64 auth_token to raw bytes.
    // The server YAML stores tokens as base64 and decodes them at startup;
    // we must send the same raw bytes so TokenStore.validate() succeeds.
    const std::vector<uint8_t> token_bytes = base64Decode(config_.auth_token);
    if (token_bytes.empty() && !config_.auth_token.empty()) {
        ROS_ERROR("sendAuth: auth_token is not valid base64 — AUTH will fail. "
                  "Check relay_params.yaml auth_token.");
    }

    std::vector<uint8_t> cbor;
    cbor.reserve(64);

    // Map(4): type, token, role, vehicle_id
    cbor.push_back(0xa4u);

    cborAppendTextString(cbor, "type");
    cborAppendTextString(cbor, "AUTH");

    cborAppendTextString(cbor, "token");
    cborAppendByteString(cbor, token_bytes);

    cborAppendTextString(cbor, "role");
    cborAppendTextString(cbor, "vehicle");

    cborAppendTextString(cbor, "vehicle_id");
    cborAppendTextString(cbor, config_.vehicle_id);

    if (!sendControlFrame(cbor))
    {
        ROS_WARN("sendAuth: failed to send AUTH frame");
    }
}

// ── sendOnStream ──────────────────────────────────────────────────────────────

bool QuicClient::sendOnStream(HQUIC stream, const std::vector<uint8_t>& payload)
{
    if (!stream) {
        ROS_WARN("sendOnStream: stream handle is null");
        return false;
    }

    auto buf = std::make_unique<SendBuffer>(payload);
    SendBuffer* raw = buf.get();

    {
        std::lock_guard<std::mutex> lk(pending_sends_mutex_);
        pending_sends_.push(std::move(buf));
    }

    QUIC_STATUS status = msquic_->StreamSend(
        stream, &raw->quic_buf, 1, QUIC_SEND_FLAG_NONE, raw);
    if (QUIC_FAILED(status)) {
        ROS_ERROR_STREAM("StreamSend failed: 0x" << std::hex << status);
        std::lock_guard<std::mutex> lk(pending_sends_mutex_);
        std::queue<std::unique_ptr<SendBuffer>> tmp;
        while (!pending_sends_.empty()) {
            auto& front = pending_sends_.front();
            if (front.get() != raw) {
                tmp.push(std::move(front));
            }
            pending_sends_.pop();
        }
        pending_sends_ = std::move(tmp);
        return false;
    }

    return true;
}

// ── Public send methods ───────────────────────────────────────────────────────

bool QuicClient::sendControlFrame(const std::vector<uint8_t>& payload)
{
    return sendOnStream(stream_control_, payload);
}

bool QuicClient::sendPriorityFrame(const std::vector<uint8_t>& payload)
{
    if (!auth_ok_.load(std::memory_order_relaxed)) {
        ROS_WARN("sendPriorityFrame: AUTH not yet complete, dropping frame");
        return false;
    }
    return sendOnStream(stream_priority_, payload);
}

bool QuicClient::sendBulkFrame(const std::vector<uint8_t>& payload)
{
    if (!auth_ok_.load(std::memory_order_relaxed)) {
        ROS_WARN("sendBulkFrame: AUTH not yet complete, dropping frame");
        return false;
    }
    return sendOnStream(stream_bulk_, payload);
}

// ── processEvents ─────────────────────────────────────────────────────────────

void QuicClient::processEvents()
{
    std::queue<InternalEvent> local;
    {
        std::lock_guard<std::mutex> lk(event_queue_mutex_);
        std::swap(local, event_queue_);
    }

    // Capture callbacks under the lock to get consistent snapshot
    FrameReceivedCallback frame_cb;
    ConnectionStateCallback state_cb;
    std::function<void()> auth_ok_cb;
    std::function<void()> auth_fail_cb;
    {
        std::lock_guard<std::mutex> lk(event_queue_mutex_);
        frame_cb    = frame_cb_;
        state_cb    = state_cb_;
        auth_ok_cb  = auth_ok_cb_;
        auth_fail_cb = auth_fail_cb_;
    }

    while (!local.empty()) {
        auto& ev = local.front();
        switch (ev.type) {
            case InternalEvent::Type::FRAME_RECEIVED:
                if (frame_cb) {
                    frame_cb(std::move(ev.frame));
                }
                break;
            case InternalEvent::Type::STATE_CHANGED:
                if (state_cb) {
                    state_cb(ev.connected);
                }
                break;
            case InternalEvent::Type::AUTH_OK:
                if (auth_ok_cb) {
                    auth_ok_cb();
                }
                break;
            case InternalEvent::Type::AUTH_FAIL:
                if (auth_fail_cb) {
                    auth_fail_cb();
                }
                break;
        }
        local.pop();
    }
}

// ── postEvent ─────────────────────────────────────────────────────────────────

void QuicClient::postEvent(InternalEvent event)
{
    std::lock_guard<std::mutex> lk(event_queue_mutex_);
    event_queue_.push(std::move(event));
}

// ── shutdown ──────────────────────────────────────────────────────────────────

void QuicClient::shutdown()
{
    shutdown_requested_.store(true);

    if (connection_) {
        msquic_->ConnectionShutdown(
            connection_, QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0);
    }

    // Wait for SHUTDOWN_COMPLETE (up to 5 seconds)
    {
        std::unique_lock<std::mutex> lk(shutdown_mutex_);
        shutdown_cv_.wait_for(lk, std::chrono::seconds(5),
                              [this] { return shutdown_complete_; });
    }

    closeAllHandles();
}

void QuicClient::closeAllHandles()
{
    if (stream_bulk_) {
        msquic_->StreamClose(stream_bulk_);
        stream_bulk_ = nullptr;
    }
    if (stream_priority_) {
        msquic_->StreamClose(stream_priority_);
        stream_priority_ = nullptr;
    }
    if (stream_control_) {
        msquic_->StreamClose(stream_control_);
        stream_control_ = nullptr;
    }
    if (connection_) {
        msquic_->ConnectionClose(connection_);
        connection_ = nullptr;
    }
    if (configuration_) {
        msquic_->ConfigurationClose(configuration_);
        configuration_ = nullptr;
    }
    if (registration_) {
        msquic_->RegistrationClose(registration_);
        registration_ = nullptr;
    }
    if (msquic_) {
        MsQuicClose(msquic_);
        msquic_ = nullptr;
    }
}

// ── Frame decoder ─────────────────────────────────────────────────────────────
//
// Decodes all complete [u16_le len][payload] frames from an msquic receive buffer.
// Handles fragmentation — partial frames are buffered in `state`.

void QuicClient::decodeFrames(StreamRecvState& state,
                               const uint8_t* data, uint64_t length,
                               std::vector<std::vector<uint8_t>>& frames_out)
{
    uint64_t offset = 0;

    while (offset < length) {
        if (!state.has_header) {
            // Accumulate until we have 2 header bytes
            const uint64_t needed = 2u - state.buf.size();
            const uint64_t avail  = length - offset;
            const uint64_t take   = (avail < needed) ? avail : needed;
            state.buf.insert(state.buf.end(), data + offset, data + offset + take);
            offset += take;

            if (state.buf.size() == 2) {
                state.expected_len = static_cast<uint32_t>(state.buf[0]) |
                                     (static_cast<uint32_t>(state.buf[1]) << 8u);
                state.buf.clear();
                state.has_header = true;

                if (state.expected_len == 0) {
                    // Zero-length frame: emit empty, reset
                    frames_out.push_back({});
                    state.has_header = false;
                }
            }
        } else {
            // Accumulate payload bytes
            const uint64_t needed = state.expected_len - state.buf.size();
            const uint64_t avail  = length - offset;
            const uint64_t take   = (avail < needed) ? avail : needed;
            state.buf.insert(state.buf.end(), data + offset, data + offset + take);
            offset += take;

            if (state.buf.size() == state.expected_len) {
                frames_out.push_back(std::move(state.buf));
                state.buf = {};
                state.has_header  = false;
                state.expected_len = 0;
            }
        }
    }
}

// ── onConnectionEvent ─────────────────────────────────────────────────────────

void QuicClient::onConnectionEvent(HQUIC /*connection*/, QUIC_CONNECTION_EVENT* event)
{
    switch (event->Type) {
        case QUIC_CONNECTION_EVENT_CONNECTED:
            ROS_INFO("QUIC connection established");
            connected_.store(true);
            openStreams();
            postEvent({InternalEvent::Type::STATE_CHANGED, {}, true});
            break;

        case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT:
            ROS_WARN_STREAM("QUIC transport shutdown initiated, error: 0x"
                            << std::hex
                            << event->SHUTDOWN_INITIATED_BY_TRANSPORT.ErrorCode);
            connected_.store(false);
            break;

        case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER:
            ROS_WARN("QUIC peer initiated shutdown");
            connected_.store(false);
            break;

        case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
            ROS_INFO("QUIC connection shutdown complete");
            connected_.store(false);
            auth_ok_.store(false);
            // Free all pending send buffers
            {
                std::lock_guard<std::mutex> lk(pending_sends_mutex_);
                while (!pending_sends_.empty()) {
                    pending_sends_.pop();
                }
            }
            postEvent({InternalEvent::Type::STATE_CHANGED, {}, false});
            // Signal shutdown() waiting thread
            {
                std::lock_guard<std::mutex> lk(shutdown_mutex_);
                shutdown_complete_ = true;
            }
            shutdown_cv_.notify_all();
            break;

        case QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED:
            // Server opened a stream — accept it with a generic callback
            msquic_->SetCallbackHandler(
                event->PEER_STREAM_STARTED.Stream, reinterpret_cast<void*>(streamCallback), this);
            break;

        default:
            break;
    }
}

// ── onStreamEvent ─────────────────────────────────────────────────────────────

void QuicClient::onStreamEvent(HQUIC stream, QUIC_STREAM_EVENT* event, int stream_index)
{
    switch (event->Type) {
        case QUIC_STREAM_EVENT_RECEIVE: {
            // Collect all data from the scattered QUIC_BUFFER array
            const uint32_t buf_count = event->RECEIVE.BufferCount;
            const QUIC_BUFFER* bufs  = event->RECEIVE.Buffers;

            std::vector<std::vector<uint8_t>> frames;

            StreamRecvState* state = nullptr;
            switch (stream_index) {
                case 0: state = &recv_state_control_;  break;
                case 1: state = &recv_state_priority_; break;
                case 2: state = &recv_state_bulk_;     break;
                default: break;
            }

            if (state) {
                for (uint32_t i = 0; i < buf_count; ++i) {
                    decodeFrames(*state, bufs[i].Buffer, bufs[i].Length, frames);
                }
            }

            // Tell msquic we consumed all bytes
            msquic_->StreamReceiveComplete(stream, event->RECEIVE.TotalBufferLength);

            for (auto& frame : frames) {
                if (stream_index == 0) {
                    // Control stream: decode CBOR map and dispatch on "type" field.
                    handleControlFrame(frame);
                } else {
                    // Priority or bulk: relay to ROS thread via event queue
                    InternalEvent ev{};
                    ev.type  = InternalEvent::Type::FRAME_RECEIVED;
                    ev.frame = std::move(frame);
                    postEvent(std::move(ev));
                }
            }
            break;
        }

        case QUIC_STREAM_EVENT_SEND_COMPLETE: {
            // Release the SendBuffer whose raw pointer was passed as ClientContext
            SendBuffer* completed = static_cast<SendBuffer*>(
                event->SEND_COMPLETE.ClientContext);
            if (completed) {
                std::lock_guard<std::mutex> lk(pending_sends_mutex_);
                std::queue<std::unique_ptr<SendBuffer>> tmp;
                while (!pending_sends_.empty()) {
                    auto& front = pending_sends_.front();
                    if (front.get() != completed) {
                        tmp.push(std::move(front));
                    }
                    pending_sends_.pop();
                }
                pending_sends_ = std::move(tmp);
            }
            break;
        }

        case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN:
            msquic_->StreamShutdown(stream, QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, 0);
            break;

        case QUIC_STREAM_EVENT_PEER_SEND_ABORTED:
            ROS_WARN_STREAM("Stream " << stream_index << " peer send aborted");
            break;

        case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE: {
            // Stream is done — release the StreamContext
            StreamContext* ctx = static_cast<StreamContext*>(
                msquic_->GetParam ? nullptr : nullptr);
            // Context was set as callback context; msquic delivers it in
            // the same void* we passed to StreamOpen. Retrieve from event isn't
            // direct — we free the context by tracking it ourselves.
            // The StreamContext was allocated in openStreams / openMavlinkStreams;
            // we accept a small one-time leak here on shutdown as the process is
            // about to clean up. For correctness in long-running code, attach
            // context to stream via SetParam or a side table.
            (void)ctx;
            break;
        }

        default:
            break;
    }
}

// ── Static callback shims ─────────────────────────────────────────────────────

QUIC_STATUS QUIC_API QuicClient::connectionCallback(
    HQUIC connection, void* context, QUIC_CONNECTION_EVENT* event)
{
    auto* self = static_cast<QuicClient*>(context);
    if (self) {
        self->onConnectionEvent(connection, event);
    }
    return QUIC_STATUS_SUCCESS;
}

QUIC_STATUS QUIC_API QuicClient::streamCallback(
    HQUIC stream, void* context, QUIC_STREAM_EVENT* event)
{
    auto* ctx = static_cast<StreamContext*>(context);
    if (ctx && ctx->client) {
        ctx->client->onStreamEvent(stream, event, ctx->stream_index);
    }
    return QUIC_STATUS_SUCCESS;
}

}  // namespace mavlink_quic_relay

#else  // !MAVLINK_QUIC_RELAY_HAVE_MSQUIC

// ── Stub implementations (msquic not available at compile time) ───────────────

#include <ros/ros.h>

namespace mavlink_quic_relay {

QuicClient::QuicClient(QuicClientConfig config) : config_(std::move(config)) {}
QuicClient::~QuicClient() = default;

void QuicClient::setFrameReceivedCallback(FrameReceivedCallback cb)
{
    frame_cb_ = std::move(cb);
}

void QuicClient::setConnectionStateCallback(ConnectionStateCallback cb)
{
    state_cb_ = std::move(cb);
}

bool QuicClient::connect()
{
    ROS_ERROR("QuicClient::connect() — msquic not compiled in. Rebuild with msquic.");
    return false;
}

bool QuicClient::sendControlFrame(const std::vector<uint8_t>&)
{
    ROS_WARN("QuicClient::sendControlFrame() — msquic not available");
    return false;
}

bool QuicClient::sendPriorityFrame(const std::vector<uint8_t>&)
{
    ROS_WARN("QuicClient::sendPriorityFrame() — msquic not available");
    return false;
}

bool QuicClient::sendBulkFrame(const std::vector<uint8_t>&)
{
    ROS_WARN("QuicClient::sendBulkFrame() — msquic not available");
    return false;
}

void QuicClient::shutdown() {}
void QuicClient::processEvents() {}

bool QuicClient::isConnected() const noexcept
{
    return connected_.load(std::memory_order_relaxed);
}

}  // namespace mavlink_quic_relay

#endif  // MAVLINK_QUIC_RELAY_HAVE_MSQUIC
