import os
import unittest
from contextlib import contextmanager
from unittest.mock import patch

os.environ.setdefault("MYSQL_HOST", "test")
os.environ.setdefault("MYSQL_USER", "test")
os.environ.setdefault("MYSQL_PASSWORD", "test")
os.environ.setdefault("MYSQL_DATABASE", "test")

from server.app import main  # noqa: E402


class FakeDatabase:
    def __init__(self):
        self.respondents = set()
        self.sessions = {}
        self.creation_keys = {}

    @contextmanager
    def connection(self):
        yield FakeConnection(self)


class FakeConnection:
    def __init__(self, database):
        self.database = database

    def cursor(self):
        return FakeCursor(self.database)


class FakeCursor:
    def __init__(self, database):
        self.database = database
        self.row = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def execute(self, sql, params=()):
        normalized = " ".join(sql.split()).lower()
        self.row = None
        if "from session_creation_keys" in normalized:
            mapping = self.database.creation_keys.get(params[0])
            if mapping:
                self.row = {"respondent_id": mapping[0], "session_id": mapping[1]}
        elif "get_lock" in normalized:
            self.row = {"acquired": 1}
        elif normalized.startswith("insert into respondents"):
            self.database.respondents.add(params[0])
        elif normalized.startswith("select id from respondents"):
            if params[0] in self.database.respondents:
                self.row = {"id": params[0]}
        elif normalized.startswith("insert into survey_sessions"):
            self.database.sessions[params[0]] = params[1]
        elif normalized.startswith("insert into session_creation_keys"):
            self.database.creation_keys[params[0]] = (params[2], params[1])
        else:
            raise AssertionError(f"Unexpected SQL: {normalized}")

    def fetchone(self):
        return self.row


class SessionCreationIdempotencyTests(unittest.TestCase):
    def test_repeated_local_session_id_returns_one_identity(self):
        database = FakeDatabase()
        body = main.SessionCreate(
            questionnaire_version="3",
            questionnaire_id="street-assessment",
            app_version="1.0",
            locale="en-US",
            local_session_id="local-session-123",
        )

        with patch.object(main, "get_conn", database.connection):
            first = main.create_session(body, None)
            second = main.create_session(body, None)

        self.assertEqual(first.respondent_id, second.respondent_id)
        self.assertEqual(first.session_id, second.session_id)
        self.assertEqual(len(database.respondents), 1)
        self.assertEqual(len(database.sessions), 1)
        self.assertEqual(len(database.creation_keys), 1)

    def test_legacy_clients_without_key_keep_create_each_time_behavior(self):
        database = FakeDatabase()
        body = main.SessionCreate(questionnaire_version="1")

        with patch.object(main, "get_conn", database.connection):
            first = main.create_session(body, None)
            second = main.create_session(body, None)

        self.assertNotEqual(first.session_id, second.session_id)
        self.assertEqual(len(database.respondents), 2)
        self.assertEqual(len(database.sessions), 2)
        self.assertEqual(len(database.creation_keys), 0)


if __name__ == "__main__":
    unittest.main()
