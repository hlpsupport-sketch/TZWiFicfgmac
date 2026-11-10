"""Hardware-free tests: a fake device that answers the recovered protocol."""
import datetime as dt, unittest
import tzone_proto as tp


class FakeScsi:
    def __init__(self): self.writes = []
    def execute(self, cdb, data_in_len=0, data_out=b""):
        assert len(cdb) == 12 and cdb[1] == 0 and cdb[9:] == b"\0\0\0"
        addr = int.from_bytes(cdb[2:6], "big"); n = int.from_bytes(cdb[6:9], "big")
        if cdb[0] == tp.OP_WRITE:
            assert addr == tp.ADDR_WRITE and n == len(data_out)
            self.writes.append(data_out); return b""
        assert cdb[0] == tp.OP_READ and n == data_in_len
        reply = {
            0x03000911: b"*CMD,000,WF501B_X,V1.2.3#",
            0x03000910: b"*CMD,000,HW9#",
            0x03000002: b"*CMD,000,ABC123456789012#",
            0x03000006: b"*CMD,006,26,11,9,1,2,3#",
            0x03000020: b"*CMD,020,MyNet,secret#",
        }[addr]
        return reply.ljust(n, b"\0")


class T(unittest.TestCase):
    def test_cdb(self):
        self.assertEqual(tp.build_cdb(0xEC, 0x03000911, 64).hex(), "ec0003000911000040000000")
        self.assertEqual(tp.build_cdb(0xCE, 0x10000000, 300).hex(), "ce001000000000012c000000")

    def test_parse(self):
        self.assertEqual(tp.parse_cmd(b"junk*CMD,a,b,c#\0\0"), ["a", "b", "c"])
        self.assertIsNone(tp.parse_cmd(b"no frame"))
        self.assertIsNone(tp.parse_cmd(b"#*CMD,a"))

    def test_info_and_config(self):
        lg = tp.Logger(FakeScsi())
        i = lg.get_info()
        self.assertEqual((i.dtype, i.hardware, i.firmware, i.device_id),
                         (tp.DTYPE_WF501B, "WF501B_X_HW9", "1.2.3", "ABC123456789012"))
        c = lg.get_wifi_config()
        self.assertEqual((c.ssid, c.password), ("MyNet", "secret"))
        self.assertEqual(c.device_time_utc, dt.datetime(2026, 11, 9, 1, 2, 3, tzinfo=dt.timezone.utc))

    def test_write(self):
        s = FakeScsi(); tp.Logger(s).set_wifi_config("Net", "pw")
        self.assertEqual(s.writes, [b"*000000,020,Net,pw#"])          # WiFi only by default
        s = FakeScsi(); tp.Logger(s).set_wifi_config("Net", "pw", set_time=True, set_alarm=True)
        self.assertEqual(s.writes[0], b"*000000,003,125,-40,100,0,1#")
        self.assertTrue(s.writes[1].startswith(b"*000000,006,") and s.writes[1].endswith(b"#"))
        self.assertEqual(s.writes[2], b"*000000,020,Net,pw#")
        with self.assertRaises(tp.TzoneError): tp.Logger(s).set_wifi_config("a,b", "")
        with self.assertRaises(tp.TzoneError): tp.Logger(s).set_device_id("short")


if __name__ == "__main__":
    unittest.main()
