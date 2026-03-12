# USB Controller Topology for EC200U-CN

## Summary

The EC200U-CN modem enumerates on `3610000.xhci`, which is the Jetson Xavier NX USB **host** controller. The modem does **not** attach to `3550000.xudc`, which is the USB **device/OTG** controller.

## Controller Roles

### `3610000.xhci`
- XHCI host controller
- Owns the downstream USB host bus where the modem appears
- This is the controller that must see VID:PID `2c7c:0901`
- No role-switch logic is needed because this path is already in host mode

### `3550000.xudc`
- USB device/OTG controller
- Used for Jetson gadget or device-mode behavior
- The EC200U-CN modem does not enumerate here
- Troubleshooting the modem by writing OTG role state is therefore the wrong fix

## Why `nv-l4t-usb-device-mode` Is Only a Precaution

`nv-l4t-usb-device-mode` manages Jetson USB device-mode behavior associated with `3550000.xudc`. Masking it is a defensive step to reduce the chance of unrelated gadget-mode configuration interfering with the platform, but it is **not** the cause of modem enumeration success or failure.

If the modem is missing from `lsusb -d 2c7c:0901`, the real problem is that the device is not visible on the host-side USB path. The answer is to fail clearly and stop downstream setup, not to toggle OTG state.

## Why OTG Role-Switch Code Is Absent

OTG role-switch code such as `echo host > /sys/...` is intentionally absent from this repository for this deployment:

- The modem is already on the XHCI host bus
- The wrong controller would be targeted by OTG workarounds
- The deployment guardrail is to validate host-bus visibility and stop if hardware is absent

The correct behavior is:
1. Optionally mask `nv-l4t-usb-device-mode` as a precaution
2. Verify `lsusb -d 2c7c:0901`
3. Continue to `lte-ecm-bootstrap.service` only when the modem is present
