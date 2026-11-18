"""usb_phone when the service runs as root (desktop/d435.sh run on a Mac where the D435 needs sudo): devicectl must
run as the user who started it, and be able to write into the service's temp folders. No phone or Xcode needed."""
import json
import os
import stat
from pathlib import Path

from fieldstation import usb_phone


def test_no_prefix_as_a_normal_user(monkeypatch):
    monkeypatch.setattr(os, "geteuid", lambda: 501)
    monkeypatch.setenv("SUDO_USER", "someone")
    assert usb_phone._user_prefix() == []


def test_root_runs_devicectl_as_the_sudo_user(monkeypatch, tmp_path):
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    monkeypatch.setenv("SUDO_USER", "fielduser")
    assert usb_phone._user_prefix() == ["sudo", "-n", "-u", "fielduser"]

    seen = {}
    dest_parent = tmp_path / "work"
    dest_parent.mkdir(mode=0o700)

    def fake_run(cmd, **kw):
        seen["cmd"] = cmd
        out = Path(cmd[cmd.index("--json-output") + 1])
        seen["out_dir_mode"] = stat.S_IMODE(out.parent.stat().st_mode)
        out.write_text(json.dumps({"result": {"devices": []}}))

        class R:
            returncode, stdout, stderr = 0, "", ""
        return R()

    monkeypatch.setattr(usb_phone.subprocess, "run", fake_run)
    usb_phone._devicectl(["device", "copy", "from", "--destination", str(dest_parent / "scan-x")])
    assert seen["cmd"][:6] == ["sudo", "-n", "-u", "fielduser", "xcrun", "devicectl"]
    assert seen["out_dir_mode"] == 0o777
    assert stat.S_IMODE(dest_parent.stat().st_mode) == 0o777


def test_root_without_sudo_user_runs_directly(monkeypatch):
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    monkeypatch.delenv("SUDO_USER", raising=False)
    assert usb_phone._user_prefix() == []
