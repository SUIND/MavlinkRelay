# EC200U-CN LTE Quick Connect Guide

Hardware: 7SEMI EC200U-CN modem, Jetson Xavier NX (Connect Tech Quark), Airtel India SIM.

---

## Prerequisites

- Modem plugged into USB port
- SIM inserted
- `lte0` interface visible (`ip link show lte0`) — if not, check the `.link` file in `network/`

---

## One-Time Setup

These steps are run once. The modem remembers the APN and autoconnect state in its own non-volatile memory.

### 1. Load the AT serial driver

The `option` driver exposes AT command ports (`/dev/ttyUSB0`, `ttyUSB1`) needed to wake the data session:

```bash
sudo modprobe option
echo "2c7c 0901" | sudo tee /sys/bus/usb-serial/drivers/option1/new_id
ls /dev/ttyUSB*   # should show ttyUSB0 and ttyUSB1
```

### 2. Set APN and connect

```bash
sudo bash -c '
exec 3<>/dev/ttyUSB0
q() { printf "%s\r\n" "$1" >&3; sleep 1; timeout 2 cat <&3 2>/dev/null | tr -d "\r" | grep -v "^$"; }
q "AT+CGDCONT=1,\"IP\",\"airtelgprs.com\""   # Airtel India APN — stored in modem NV
q "AT+QNETDEVCTL=1,1,1"                        # Connect + enable persistent autoconnect
exec 3>&-
'
sleep 3
ip addr show lte0   # should show inet 100.x.x.x
```

### 3. Make it survive reboots (automated)

Run the installer — it auto-detects your modem's MAC, loads the `option` driver at boot, and sets up all systemd services:

```bash
sudo bash install.sh --apn airtelgprs.com
```

After this the modem will auto-connect on every boot or USB replug without manual intervention.

---

## Verify

```bash
ip addr show lte0          # inet address present, state UP
ping -I lte0 8.8.8.8 -c 3  # live data path
```

---

## Modem Diagnostics (without rebooting)

Check modem state at any time:

```bash
sudo bash -c '
exec 3<>/dev/ttyUSB0
q() { printf "%s\r\n" "$1" >&3; sleep 1; timeout 2 cat <&3 2>/dev/null | tr -d "\r" | grep -v "^$"; }
echo "SIM:";      q "AT+CPIN?"
echo "Network:";  q "AT+CEREG?"
echo "APN:";      q "AT+CGDCONT?"
echo "Connect:";  q "AT+QNETDEVCTL?"
exec 3>&-
'
```

Expected healthy output:
```
SIM:      +CPIN: READY
Network:  +CEREG: 0,1    (1=home, 5=roaming)
APN:      +CGDCONT: 1,"IP","airtelgprs.com"
Connect:  +QNETDEVCTL: 1,...
```

---

## Soft-Replug (test persistence without rebooting)

```bash
echo "1-1" | sudo tee /sys/bus/usb/drivers/usb/unbind
sleep 3
echo "1-1" | sudo tee /sys/bus/usb/drivers/usb/bind
sleep 8
ip addr show lte0
```
