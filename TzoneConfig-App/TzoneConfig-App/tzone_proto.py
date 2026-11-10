"""
Tzone data-logger protocol + USB mass-storage (Bulk-Only Transport) transport.

Recovered from the Windows tool (UsbConfig.exe + SCSI.dll):

  * The logger enumerates as a USB mass-storage device whose SCSI INQUIRY
    reports vendor "Tzone" and product "DataLogger".
  * The Windows tool sends 12-byte vendor CDBs through IOCTL_SCSI_PASS_THROUGH:
        byte 0      opcode   0xEC = read from device, 0xCE = write to device
        byte 1      0
        bytes 2-5   "address" (big-endian 32 bit)
        bytes 6-8   transfer length (big-endian 24 bit)
        bytes 9-11  0
  * Payloads are ASCII text frames "*CMD,<code>,<arg>,...#".
      read  0xEC, address 0x03000000+n -> device replies "*CMD,...#"
      write 0xCE, address 0x10000000   -> "*<password>,<code>,<args>#"
  * Default password is "000000".

This module replaces SCSI.dll (Windows only) with a libusb implementation of the
USB Bulk-Only Transport, which works on macOS.
"""
from __future__ import annotations

import struct
import datetime as _dt
from dataclasses import dataclass, field
from typing import Optional

OP_READ = 0xEC
OP_WRITE = 0xCE
ADDR_WRITE = 0x10000000

VENDOR = "Tzone"
PRODUCT = "DataLogger"

DEFAULT_PASSWORD = "000000"

# Read addresses (all reply with a "*CMD,...#" frame)
ADDR_ID = 0x03000002
ADDR_TIME = 0x03000006
ADDR_HW_EXTRA = 0x03000910
ADDR_HW_MODEL = 0x03000911
ADDR_WIFI = 0x03000020

# Device types as used by the Windows tool (Device.DType)
DTYPE_UNKNOWN = 0
DTYPE_DEFAULT = 1
DTYPE_WF501 = 2
DTYPE_WF501B = 3
DTYPE_WF502 = 5
DTYPE_WF502B = 6
WIFI_DTYPES = (DTYPE_WF501, DTYPE_WF501B, DTYPE_WF502, DTYPE_WF502B)
_MODEL_TO_DTYPE = {
    "WF501": DTYPE_WF501,
    "WF501B": DTYPE_WF501B,
    "WF502": DTYPE_WF502,
    "WF502B": DTYPE_WF502B,
}
# Types for which the Windows tool does NOT append the second hardware field.
_NO_HW_EXTRA = (1, 8, 13, 11, 14)


class TzoneError(Exception):
    pass


# --------------------------------------------------------------------------
# CDB / frame helpers (pure functions - unit-testable without hardware)
# --------------------------------------------------------------------------
def build_cdb(opcode: int, address: int, length: int) -> bytes:
    if not 0 <= length <= 0xFFFFFF:
        raise ValueError("length out of range")
    return bytes([
        opcode & 0xFF, 0,
        (address >> 24) & 0xFF, (address >> 16) & 0xFF, (address >> 8) & 0xFF, address & 0xFF,
        (length >> 16) & 0xFF, (length >> 8) & 0xFF, length & 0xFF,
        0, 0, 0,
    ])


def parse_cmd(raw: bytes | str) -> Optional[list[str]]:
    """Port of MainWindow.GetCmdPackage: returns the comma-split fields that
    follow '*CMD,' (field 0 is the command code, field 1 the first value)."""
    text = raw.decode("ascii", errors="ignore") if isinstance(raw, (bytes, bytearray)) else raw
    start = text.find("*CMD,")
    end = text.find("#")
    if start == -1 or end == -1 or start > end:
        return None
    return text[start + len("*CMD,"):end].split(",")


def frame(password: str, code: str, *args) -> bytes:
    return ("*" + ",".join([password, code, *[_fmt(a) for a in args]]) + "#").encode("ascii")


def _fmt(v) -> str:
    if isinstance(v, float) and v == int(v):
        return str(int(v))
    return str(v)


# --------------------------------------------------------------------------
# Transport: USB Bulk-Only Transport over libusb (pyusb)
# --------------------------------------------------------------------------
class BotTransport:
    """Executes SCSI CDBs on a USB mass-storage interface."""

    def __init__(self, dev, intf_number, ep_in, ep_out, timeout_ms=10000):
        self.dev, self.intf, self.ep_in, self.ep_out = dev, intf_number, ep_in, ep_out
        self.timeout = timeout_ms
        self._tag = 0

    # -- low level
    def execute(self, cdb: bytes, data_in_len: int = 0, data_out: bytes = b"") -> bytes:
        import usb.core
        self._tag = (self._tag + 1) & 0xFFFFFFFF
        out = bool(data_out)
        xfer = len(data_out) if out else data_in_len
        flags = 0x00 if (out or xfer == 0) else 0x80
        cbw = struct.pack("<4sIIBBB", b"USBC", self._tag, xfer, flags, 0, len(cdb)) + cdb.ljust(16, b"\0")
        self.dev.write(self.ep_out.bEndpointAddress, cbw, self.timeout)
        data = b""
        try:
            if xfer:
                if out:
                    self.dev.write(self.ep_out.bEndpointAddress, data_out, self.timeout)
                else:
                    data = bytes(self.dev.read(self.ep_in.bEndpointAddress, xfer, self.timeout))
        except usb.core.USBError:
            self.dev.clear_halt(self.ep_in.bEndpointAddress if not out else self.ep_out.bEndpointAddress)
        try:
            csw = bytes(self.dev.read(self.ep_in.bEndpointAddress, 13, self.timeout))
        except usb.core.USBError:
            self.dev.clear_halt(self.ep_in.bEndpointAddress)
            csw = bytes(self.dev.read(self.ep_in.bEndpointAddress, 13, self.timeout))
        sig, tag, _residue, status = struct.unpack("<4sIIB", csw[:13])
        if sig != b"USBS" or tag != self._tag:
            raise TzoneError("Invalid USB command status wrapper (device needs re-plugging)")
        if status != 0:
            raise TzoneError(f"SCSI command failed (CSW status {status})")
        return data

    def inquiry(self) -> tuple[str, str, str]:
        d = self.execute(bytes([0x12, 0, 0, 0, 36, 0]), 36)
        f = lambda b: b.decode("ascii", "ignore").strip("\0 ").strip()
        return f(d[8:16]), f(d[16:32]), f(d[32:36])

    def close(self):
        import usb.util
        try:
            usb.util.release_interface(self.dev, self.intf)
        except Exception:
            pass
        usb.util.dispose_resources(self.dev)


def open_logger(vendor: str = VENDOR, product: str = PRODUCT) -> BotTransport:
    """Find the first attached logger and return an opened transport."""
    try:
        import usb.core, usb.util
    except ImportError as e:  # pragma: no cover
        raise TzoneError("pyusb is not installed - run:  pip3 install pyusb") from e
    backend = None
    try:  # bundled libusb (no Homebrew needed)
        import libusb_package
        backend = libusb_package.get_libusb1_backend()
    except ImportError:
        import usb.backend.libusb1 as lb
        backend = lb.get_backend()
    if backend is None:
        raise TzoneError("libusb not found - run:  pip3 install libusb-package")

    found_msc = False
    last_err = None
    for dev in usb.core.find(find_all=True, backend=backend):
        for cfg in dev:
            for intf in cfg:
                if (intf.bInterfaceClass, intf.bInterfaceSubClass, intf.bInterfaceProtocol) != (8, 6, 0x50):
                    continue
                found_msc = True
                try:
                    # Ask macOS to release the logger from its storage driver (needs admin rights).
                    num = intf.bInterfaceNumber
                    try:
                        dev.detach_kernel_driver(num)
                        import time
                        time.sleep(1.5)
                        again = usb.core.find(idVendor=dev.idVendor, idProduct=dev.idProduct, backend=backend)
                        if again is not None:
                            dev = again
                            intf = usb.util.find_descriptor(dev.get_active_configuration(), bInterfaceNumber=num) or intf
                    except (NotImplementedError, usb.core.USBError, ValueError) as e:
                        last_err = e
                    try:
                        dev.set_configuration()
                    except usb.core.USBError:
                        pass
                    usb.util.claim_interface(dev, intf.bInterfaceNumber)
                    ep_in = usb.util.find_descriptor(intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN
                                                     and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
                    ep_out = usb.util.find_descriptor(intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT
                                                      and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
                    t = BotTransport(dev, intf.bInterfaceNumber, ep_in, ep_out)
                    v, p, _rev = t.inquiry()
                    if v == vendor and p == product:
                        return t
                    t.close()
                except usb.core.USBError as e:
                    last_err = e
                except TzoneError as e:
                    last_err = e
    if found_msc and last_err is not None:
        raise TzoneError(
            "A USB storage device was found but could not be opened "
            f"({last_err}).\nEject (unmount) the logger's disk in Finder or run "
            "'diskutil unmountDisk /dev/diskN', then run this tool with sudo.")
    raise TzoneError("No Tzone logger found. Plug it in with the USB cable and try again.")


# --------------------------------------------------------------------------
# High-level protocol
# --------------------------------------------------------------------------
@dataclass
class DeviceInfo:
    dtype: int = DTYPE_DEFAULT
    hardware: str = ""
    firmware: str = ""
    device_id: str = ""


@dataclass
class WifiConfig:
    device_time_utc: Optional[_dt.datetime] = None
    ssid: str = ""
    password: str = ""
    raw_time: Optional[list] = None


class Logger:
    def __init__(self, transport, password: str = DEFAULT_PASSWORD):
        self.t = transport
        self.password = password

    # raw
    def read_cmd(self, address: int, length: int) -> Optional[list[str]]:
        return parse_cmd(self.t.execute(build_cdb(OP_READ, address, length), length))

    def write_cmd(self, payload: bytes) -> None:
        self.t.execute(build_cdb(OP_WRITE, ADDR_WRITE, len(payload)), 0, payload)

    # info (MainWindow.GetDeviceInfo)
    def get_info(self) -> DeviceInfo:
        info = DeviceInfo()
        p = self.read_cmd(ADDR_HW_MODEL, 64)
        if not p or len(p) <= 1:
            raise TzoneError("Device did not answer the model query.")
        info.hardware = p[1]
        info.dtype = _MODEL_TO_DTYPE.get(p[1].upper().split("_")[0], DTYPE_DEFAULT)
        if p[-1].upper().find("V") == 0:
            info.firmware = p[-1][1:]
        if info.dtype not in _NO_HW_EXTRA:
            q = self.read_cmd(ADDR_HW_EXTRA, 64)
            if q and len(q) > 1:
                info.hardware += "_" + q[1]
        p = self.read_cmd(ADDR_ID, 25)
        if p and len(p) > 1:
            info.device_id = p[1]
        return info

    # WF501 / WF502 family (MainWindow.GetDeviceConfig_WF501)
    def get_wifi_config(self) -> WifiConfig:
        cfg = WifiConfig()
        p = self.read_cmd(ADDR_TIME, 50)
        cfg.raw_time = p
        if p and len(p) == 7:
            try:
                y, mo, d, h, mi, s = (int(x) for x in p[1:7])
                y += 2000 if y < 100 else 0
                cfg.device_time_utc = _dt.datetime(y, mo, d, h, mi, s, tzinfo=_dt.timezone.utc)
            except ValueError:
                pass
        p = self.read_cmd(ADDR_WIFI, 150)
        if p and len(p) == 3:
            cfg.ssid, cfg.password = p[1], p[2]
        return cfg

    def set_wifi_config(self, ssid: str, password: str, *, set_time: bool = False, set_alarm: bool = False,
                        temp_alarm=(125.0, -40.0), hum_alarm=(100.0, 0.0), alarm_interval: int = 1) -> None:
        """WiFi (020) always; alarm limits (003) and clock (006) only if asked - the Windows tool writes all three."""
        for field_name, v in (("WiFi name", ssid), ("WiFi password", password)):
            if "#" in v or "," in v or "\0" in v:
                raise TzoneError(f"{field_name} may not contain '#' or ','")
            if len(v.encode("ascii", "strict")) > 63:
                raise TzoneError(f"{field_name} must be at most 63 characters")
        pw = self.password
        if set_alarm:
            self.write_cmd(frame(pw, "003", temp_alarm[0], temp_alarm[1], hum_alarm[0], hum_alarm[1], alarm_interval))
        if set_time:
            n = _dt.datetime.now(_dt.timezone.utc)
            self.write_cmd(frame(pw, "006", n.strftime("%y"), n.strftime("%m"), n.strftime("%d"),
                                 n.strftime("%H"), n.strftime("%M"), n.strftime("%S")))
        self.write_cmd(frame(pw, "020", ssid, password))

    def set_device_id(self, new_id: str) -> None:
        """Factory-only in the Windows tool ('*pw,002,ID#'). Exposed for completeness."""
        import re
        if not re.fullmatch(r"[0-9A-Za-z]{15}", new_id):
            raise TzoneError("ID must be 15 letters/digits")
        self.write_cmd(frame(self.password, "002", new_id))
