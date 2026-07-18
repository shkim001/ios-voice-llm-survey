import os
import unittest

os.environ.setdefault("MYSQL_HOST", "test")
os.environ.setdefault("MYSQL_USER", "test")
os.environ.setdefault("MYSQL_PASSWORD", "test")
os.environ.setdefault("MYSQL_DATABASE", "test")

from server.app import main  # noqa: E402


class PackageLocationSummaryTests(unittest.TestCase):
    def test_place_search_is_indexed_as_label_but_never_as_device_gps(self):
        summary = main.safe_json_summary(
            {
                "location_label": "Butler Library",
                "location": {
                    "status": "available",
                    "source": "place_search",
                    "label": "Butler Library",
                    "formatted_address": "535 W 114th St, New York, NY",
                    "latitude": 40.8063,
                    "longitude": -73.9632,
                },
                "respondent_info": {"location": "Original typed location"},
            }
        )

        self.assertEqual(summary["location_label"], "Butler Library")
        self.assertIsNone(summary["gps_lat"])
        self.assertIsNone(summary["gps_lon"])

    def test_device_gps_location_fallback_remains_indexable(self):
        summary = main.safe_json_summary(
            {
                "location": {
                    "status": "available",
                    "source": "device_gps",
                    "label": "GPS location",
                    "latitude": 40.8,
                    "longitude": -73.9,
                }
            }
        )

        self.assertEqual(summary["gps_lat"], 40.8)
        self.assertEqual(summary["gps_lon"], -73.9)


if __name__ == "__main__":
    unittest.main()
