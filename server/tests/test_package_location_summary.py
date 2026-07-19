import os
import unittest

os.environ.setdefault("MYSQL_HOST", "test")
os.environ.setdefault("MYSQL_USER", "test")
os.environ.setdefault("MYSQL_PASSWORD", "test")
os.environ.setdefault("MYSQL_DATABASE", "test")

from server.app import main  # noqa: E402


class PackageLocationSummaryTests(unittest.TestCase):
    def test_location_info_is_first_class_and_precedes_legacy_location(self):
        package = {
            "location_info": {
                "mode": "fixed",
                "collection_method": "saved_survey_location",
                "location_name": "Canaan Senior Service Center",
                "formatted_address": "1428 5th Ave, New York, NY 10035",
                "latitude": 40.7991,
                "longitude": -73.9475,
            },
            "location": {
                "label": "Stale compatibility label",
                "latitude": 1,
                "longitude": 2,
                "source": "legacy",
            },
        }

        location = main.package_location_summary(package)

        self.assertEqual(location["mode"], "fixed")
        self.assertEqual(location["collection_method"], "saved_survey_location")
        self.assertEqual(location["label"], "Canaan Senior Service Center")
        self.assertEqual(location["formatted_address"], "1428 5th Ave, New York, NY 10035")
        self.assertEqual(location["latitude"], 40.7991)
        self.assertEqual(location["longitude"], -73.9475)
        self.assertTrue(main.original_package_has_location(package))

    def test_fixed_location_info_without_coordinates_remains_original_location(self):
        package = {
            "location_info": {
                "mode": "fixed",
                "collection_method": "saved_survey_location",
                "location_name": "Canaan Senior Service Center",
                "formatted_address": "1428 5th Ave, New York, NY 10035",
                "latitude": None,
                "longitude": None,
            }
        }

        location = main.package_location_summary(package)

        self.assertEqual(location["label"], "Canaan Senior Service Center")
        self.assertEqual(location["formatted_address"], "1428 5th Ave, New York, NY 10035")
        self.assertIsNone(location["latitude"])
        self.assertIsNone(location["longitude"])
        self.assertTrue(main.original_package_has_location(package))

    def test_no_location_info_stays_distinct_from_failed_or_missing_location(self):
        package = {
            "location_info": {
                "mode": "none",
                "collection_method": "intentionally_not_collected",
                "latitude": None,
                "longitude": None,
            },
            "respondent_info": {"location": "Respondent-entered neighborhood"},
        }

        location = main.package_location_summary(package)
        summary = main.safe_json_summary(package)

        self.assertEqual(location["mode"], "none")
        self.assertEqual(location["source"], "intentionally_not_collected")
        self.assertIsNone(location["label"])
        self.assertIsNone(summary["location_label"])
        self.assertFalse(main.original_package_has_location(package))

    def test_admin_override_remains_separate_and_takes_effective_precedence(self):
        row = {
            "admin_location_label": "Admin corrected location",
            "admin_formatted_address": "535 W 114th St, New York, NY",
            "admin_location_lat": 40.8063,
            "admin_location_lon": -73.9632,
            "admin_location_updated_at": None,
        }

        override = main.admin_location_override_from_row(row)

        self.assertEqual(override["source"], "admin_override")
        self.assertEqual(override["label"], "Admin corrected location")
        self.assertEqual(override["latitude"], 40.8063)

    def test_admin_summary_exposes_current_respondent_contact_fields(self):
        summary = main.admin_json_summary(
            {
                "respondent_info": {
                    "is_anonymous": False,
                    "name": "Example Respondent",
                    "email": "respondent@example.com",
                    "age_range": "25-34",
                    "gender": "Prefer not to say",
                    "race": "Asian",
                    "location": "Morningside Heights",
                }
            }
        )

        self.assertEqual(summary["respondent_name"], "Example Respondent")
        self.assertEqual(summary["respondent_email"], "respondent@example.com")
        self.assertEqual(summary["respondent_location"], "Morningside Heights")

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

        location = main.package_location_summary(
            {
                "location": {
                    "status": "available",
                    "source": "place_search",
                    "label": "Butler Library",
                    "formatted_address": "535 W 114th St, New York, NY",
                    "latitude": 40.8063,
                    "longitude": -73.9632,
                }
            }
        )
        self.assertEqual(location["formatted_address"], "535 W 114th St, New York, NY")
        self.assertEqual(location["latitude"], 40.8063)
        self.assertEqual(location["longitude"], -73.9632)
        self.assertTrue(main.original_package_has_location({"location": location}))

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

    def test_empty_location_can_receive_an_admin_override(self):
        package = {
            "location": {
                "status": "unavailable",
                "source": "none",
                "label": "Respondent form fallback that is not an interview location",
                "latitude": None,
                "longitude": None,
            },
            "trajectory_points": [],
        }

        self.assertFalse(main.original_package_has_location(package))

    def test_legacy_label_without_explicit_none_source_remains_original_location(self):
        package = {"location_label": "Legacy address-only location"}

        self.assertTrue(main.original_package_has_location(package))

    def test_legacy_trajectory_counts_as_original_location(self):
        package = {"trajectory_points": [{"lat": 40.8, "lon": -73.9}]}

        self.assertTrue(main.original_package_has_location(package))
        location = main.package_location_summary(package)
        self.assertEqual(location["latitude"], 40.8)
        self.assertEqual(location["longitude"], -73.9)


if __name__ == "__main__":
    unittest.main()
