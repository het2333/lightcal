import base64
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from services.depth_cloud_pipeline import _read_auxiliary_images, _read_json


def test_capture_metadata_and_auxiliary_images_are_read_together(tmp_path):
    capture_dir = tmp_path / "cap_test"
    capture_dir.mkdir()
    rgb = capture_dir / "rgb.jpg"
    rgb.write_bytes(b"main")
    metadata = capture_dir / "metadata.json"
    metadata.write_text(json.dumps({"camera": {"fx": 912.5}}), encoding="utf-8")
    (capture_dir / "auxiliary_0.jpg").write_bytes(b"label")
    (capture_dir / "auxiliary_2.jpg").write_bytes(b"scale")
    (capture_dir / "auxiliary_4.jpg").write_bytes(b"ignored")

    assert _read_json(metadata) == {"camera": {"fx": 912.5}}
    assert _read_auxiliary_images(rgb) == [
        base64.b64encode(b"label").decode("ascii"),
        base64.b64encode(b"scale").decode("ascii"),
    ]


def test_invalid_capture_metadata_fails_closed(tmp_path):
    metadata = tmp_path / "metadata.json"
    metadata.write_text("not-json", encoding="utf-8")

    assert _read_json(metadata) == {}
    assert _read_json(tmp_path / "missing.json") == {}
