"""生产版 VNC 管理脚本测试，不连接真实 TurboVNC。"""

import json
import os
import subprocess
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "vnc_manager.sh"


def invoke(
    tmp_path: Path, *args: str, running: tuple[str, ...] = (),
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    calls = tmp_path / "calls.log"
    calls.unlink(missing_ok=True)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir(exist_ok=True)
    username = subprocess.check_output(["id", "-un"], text=True).strip()
    getent = fake_bin / "getent"
    getent.write_text(
        '#!/bin/sh\n'
        'if [ "$1" = passwd ]; then\n'
        f'  echo "{username}:x:1000:1000:test:{tmp_path}:/bin/bash"\n'
        'fi\n'
    )
    getent.chmod(0o755)
    flock = fake_bin / "flock"
    flock.write_text("#!/bin/sh\nexit 0\n")
    flock.chmod(0o755)
    ps = fake_bin / "ps"
    ps.write_text(
        '#!/bin/sh\n'
        'for display in $VNC_RUNNING_DISPLAYS; do\n'
        '  echo "$VNC_TEST_UID Xvnc /opt/TurboVNC/bin/Xvnc $display"\n'
        'done\n'
    )
    ps.chmod(0o755)
    server = tmp_path / "vncserver"
    server.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$VNC_CALLS"\n')
    server.chmod(0o755)
    env = os.environ.copy()
    env.update(
        VNCSERVER_BIN=str(server),
        VNC_DESKTOP_USER=username,
        VNC_CALLS=str(calls),
        VNC_RUNNING_DISPLAYS=" ".join(running),
        VNC_TEST_UID=subprocess.check_output(["id", "-u"], text=True).strip(),
        PATH=f"{fake_bin}:{env['PATH']}",
    )
    result = subprocess.run(
        ["bash", str(SCRIPT), *args],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    return result, calls.read_text().splitlines() if calls.exists() else []


def test_create_defaults_to_four_and_returns_json(tmp_path: Path) -> None:
    result, calls = invoke(tmp_path, "create")
    assert result.returncode == 0
    assert len(calls) == 4
    assert calls[0] == ":1 -geometry 1920x1080 -depth 24 -localhost no -nevershared -securitytypes none"
    assert calls[-1].startswith(":4 ")
    rows = json.loads(result.stdout)
    assert [row["display"] for row in rows] == [":1", ":2", ":3", ":4"]
    assert "X11 sockets" in result.stderr
    assert "TurboVNC Xvnc processes" in result.stderr
    assert "Xorg processes" in result.stderr


def test_create_count_and_stop_modes(tmp_path: Path) -> None:
    result, calls = invoke(tmp_path, "create", "-n", "2")
    assert result.returncode == 0
    assert len(calls) == 2

    result, calls = invoke(tmp_path, "stop", ":2")
    assert result.returncode == 0
    assert calls == ["-kill :2"]

    result, calls = invoke(tmp_path, "stop")
    assert result.returncode == 0
    assert calls == ["-kill :1", "-kill :2", "-kill :3", "-kill :4"]


def test_create_skips_running_desktops(tmp_path: Path) -> None:
    result, calls = invoke(tmp_path, "create", "-n", "4", running=(":1", ":3"))
    assert result.returncode == 0
    assert [call.split()[0] for call in calls] == [":2", ":4"]
    assert ":1 已运行，跳过" in result.stderr
    assert ":2 未运行，开始创建" in result.stderr
    rows = json.loads(result.stdout)
    assert [row["state"] for row in rows] == [
        "running", "stopped", "running", "stopped",
    ]


def test_repeated_create_with_all_desktops_running_does_nothing(tmp_path: Path) -> None:
    result, calls = invoke(
        tmp_path, "create", "-n", "4", running=(":1", ":2", ":3", ":4"),
    )
    assert result.returncode == 0
    assert calls == []


def test_rejects_out_of_range_display(tmp_path: Path) -> None:
    result, calls = invoke(tmp_path, "stop", ":5")
    assert result.returncode == 2
    assert calls == []
    assert "display 必须" in result.stderr


def test_no_arguments_prints_help(tmp_path: Path) -> None:
    result, calls = invoke(tmp_path)
    assert result.returncode == 0
    assert calls == []
    assert "create [-n 1-4]" in result.stdout
    assert "stop [:[1-4]]" in result.stdout
