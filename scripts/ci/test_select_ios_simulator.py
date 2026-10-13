"""Run with: python3 -m unittest discover -s scripts/ci (works on Linux, no extra deps)."""

import unittest

import select_ios_simulator as sel

IOS_26 = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
IOS_26_1 = "com.apple.CoreSimulator.SimRuntime.iOS-26-1"
IOS_18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-5"


def dev(name, udid, available=True):
    return {"name": name, "udid": udid, "isAvailable": available}


class SelectTests(unittest.TestCase):
    def test_prefers_iphone_17_when_installed(self):
        devices = {IOS_26: [dev("iPhone 17 Pro", "PRO"), dev("iPhone 17", "BASE")]}
        self.assertEqual(sel.select(devices)[0], "BASE")

    def test_falls_back_to_newest_plain_iphone(self):
        devices = {IOS_26: [dev("iPhone 17 Pro", "PRO"), dev("iPhone Air", "AIR"),
                            dev("iPhone 18", "N18"), dev("iPad Pro", "PAD")]}
        self.assertEqual(sel.select(devices)[0], "N18")

    def test_falls_back_to_variant_when_no_plain_iphone(self):
        devices = {IOS_26: [dev("iPhone 17 Pro", "PRO"), dev("iPad Pro", "PAD")]}
        self.assertEqual(sel.select(devices)[0], "PRO")

    def test_uses_newest_runtime(self):
        devices = {IOS_26: [dev("iPhone 17", "OLD")], IOS_26_1: [dev("iPhone 17", "NEW")]}
        self.assertEqual(sel.select(devices)[0], "NEW")

    def test_ignores_old_runtimes_other_platforms_and_unavailable(self):
        devices = {
            IOS_18: [dev("iPhone 16", "OLD")],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [dev("iPhone Watch", "W")],
            IOS_26: [dev("iPhone 17", "GONE", available=False)],
        }
        self.assertIsNone(sel.select(devices))


if __name__ == "__main__":
    unittest.main()
