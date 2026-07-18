import os
import unittest

os.environ.setdefault("MYSQL_HOST", "test")
os.environ.setdefault("MYSQL_USER", "test")
os.environ.setdefault("MYSQL_PASSWORD", "test")
os.environ.setdefault("MYSQL_DATABASE", "test")

from server.app import main  # noqa: E402


class APISurfaceTests(unittest.TestCase):
    def test_package_routes_remain_and_legacy_row_routes_are_removed(self):
        route_methods = {
            (route.path, method)
            for route in main.app.routes
            for method in getattr(route, "methods", set())
        }

        self.assertIn(("/sessions", "POST"), route_methods)
        self.assertIn(("/sessions/{session_id}/package", "POST"), route_methods)
        self.assertIn(("/questionnaires/active", "GET"), route_methods)
        self.assertIn(("/admin/sessions", "GET"), route_methods)
        self.assertIn(("/admin/sessions/{session_id}/location", "PUT"), route_methods)

        self.assertNotIn(("/sessions/{session_id}/answers", "POST"), route_methods)
        self.assertNotIn(("/sessions/{session_id}/audio", "POST"), route_methods)
        self.assertNotIn(("/respondents/{respondent_id}/trajectory", "POST"), route_methods)
        self.assertNotIn(("/respondents/{respondent_id}/trajectory", "GET"), route_methods)
        self.assertNotIn(("/llm-events", "POST"), route_methods)


if __name__ == "__main__":
    unittest.main()
