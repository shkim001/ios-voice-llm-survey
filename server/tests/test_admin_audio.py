import os
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

os.environ.setdefault("MYSQL_HOST", "test")
os.environ.setdefault("MYSQL_USER", "test")
os.environ.setdefault("MYSQL_PASSWORD", "test")
os.environ.setdefault("MYSQL_DATABASE", "test")

from fastapi import HTTPException  # noqa: E402
from server.app import main  # noqa: E402


class FakeCursor:
    def __init__(self, row):
        self.row = row

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def execute(self, sql, params=()):
        self.params = params

    def fetchone(self):
        return self.row


class FakeConnection:
    def __init__(self, row):
        self.row = row

    def cursor(self):
        return FakeCursor(self.row)


@contextmanager
def fake_connection(row):
    yield FakeConnection(row)


class AdminAudioTests(unittest.TestCase):
    def test_audio_can_be_served_inline_or_as_download(self):
        session_id = str(uuid4())
        with tempfile.TemporaryDirectory() as directory:
            storage_root = Path(directory)
            audio_path = storage_root / session_id / "original recording.m4a"
            audio_path.parent.mkdir()
            audio_path.write_bytes(b"audio-data")
            row = {
                "audio_path": f"{session_id}/{audio_path.name}",
                "audio_original_filename": audio_path.name,
            }

            with (
                patch.object(main, "SURVEY_PACKAGE_STORAGE_DIR", storage_root),
                patch.object(main, "get_conn", lambda: fake_connection(row)),
            ):
                inline = main.admin_get_session_audio(session_id, False, None)
                download = main.admin_get_session_audio(session_id, True, None)

            self.assertEqual(Path(inline.path), audio_path.resolve())
            self.assertIn("inline", inline.headers["content-disposition"])
            self.assertIn("attachment", download.headers["content-disposition"])
            self.assertEqual(inline.media_type, "audio/mp4")

    def test_missing_audio_returns_not_found(self):
        session_id = str(uuid4())
        with tempfile.TemporaryDirectory() as directory:
            with (
                patch.object(main, "SURVEY_PACKAGE_STORAGE_DIR", Path(directory)),
                patch.object(
                    main,
                    "get_conn",
                    lambda: fake_connection(
                        {"audio_path": None, "audio_original_filename": None}
                    ),
                ),
            ):
                with self.assertRaises(HTTPException) as context:
                    main.admin_get_session_audio(session_id, False, None)

            self.assertEqual(context.exception.status_code, 404)


if __name__ == "__main__":
    unittest.main()
