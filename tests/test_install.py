"""安装脚本测试只使用临时目录，避免触碰宿主机 systemd。"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest


@pytest.fixture
def bundle(tmp_path: Path) -> tuple[Path, dict[str, str]]:
    source = Path(__file__).resolve().parents[1]
    work = tmp_path / "bundle"
    (work / "dist").mkdir(parents=True)
    shutil.copy2(source / "install.sh", work / "install.sh")
    shutil.copy2(source / "vnc-worker.service", work / "vnc-worker.service")
    (work / "dist" / "vnc_worker").write_text("#!/bin/sh\nexit 0\n")
    (work / "dist" / "vnc_worker").chmod(0o755)
    manager = tmp_path / "vnc_manager.sh"
    manager.write_text("#!/bin/sh\nexit 0\n")
    manager.chmod(0o755)
    shared = tmp_path / "shared"
    shared.mkdir()
    config = (source / "vnc-worker.env.example").read_text()
    config = config.replace(
        "VNC_MANAGER_SCRIPT=/opt/vnc_manager/vnc_manager.sh",
        f"VNC_MANAGER_SCRIPT={manager}",
    ).replace(
        "VNC_SHARED_ROOT=/mnt/shared-tests",
        f"VNC_SHARED_ROOT={shared}",
    )
    (work / "vnc-worker.env").write_text(config)
    systemctl = tmp_path / "fake-systemctl"
    systemctl.write_text('#!/bin/sh\necho "$@" >> "$SYSTEMCTL_CALLS"\n')
    systemctl.chmod(0o755)
    journalctl = tmp_path / "fake-journalctl"
    journalctl.write_text('#!/bin/sh\necho "$@" >> "$JOURNALCTL_CALLS"\n')
    journalctl.chmod(0o755)
    env = os.environ.copy()
    env.update(
        VNC_BUILDER_INSTALL_DIR=str(tmp_path / "installed"),
        VNC_BUILDER_CONFIG_FILE=str(tmp_path / "etc" / "vnc-worker.env"),
        VNC_BUILDER_UNIT_FILE=str(tmp_path / "systemd" / "vnc-worker.service"),
        VNC_BUILDER_SYSTEMCTL=str(systemctl),
        VNC_BUILDER_JOURNALCTL=str(journalctl),
        SYSTEMCTL_CALLS=str(tmp_path / "systemctl.log"),
        JOURNALCTL_CALLS=str(tmp_path / "journalctl.log"),
    )
    return work, env


def run(bundle: tuple[Path, dict[str, str]], *args: str) -> subprocess.CompletedProcess[str]:
    work, env = bundle
    return subprocess.run(
        ["bash", str(work / "install.sh"), *args],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_install_update_status_and_uninstall(bundle: tuple[Path, dict[str, str]]) -> None:
    work, env = bundle
    assert run(bundle, "install").returncode == 0
    installed = Path(env["VNC_BUILDER_INSTALL_DIR"]) / "vnc_worker"
    config = Path(env["VNC_BUILDER_CONFIG_FILE"])
    unit = Path(env["VNC_BUILDER_UNIT_FILE"])
    assert installed.is_file()
    assert config.stat().st_mode & 0o777 == 0o600
    assert f"ExecStart={installed} run" in unit.read_text()

    config.write_text(config.read_text().replace("192.168.10.21", "192.168.10.22"))
    assert run(bundle, "install").returncode == 0
    assert "VNC_WORKER_ID=192.168.10.22" in config.read_text()
    assert run(bundle, "status").returncode == 0
    assert run(bundle, "logs").returncode == 0
    assert "status --no-pager vnc-worker.service" in Path(env["SYSTEMCTL_CALLS"]).read_text()
    assert "-u vnc-worker.service -f" in Path(env["JOURNALCTL_CALLS"]).read_text()
    assert run(bundle, "uninstall").returncode == 0
    assert not installed.exists()
    assert not unit.exists()
    assert config.exists()
    assert run(bundle, "uninstall", "--purge").returncode == 0
    assert not config.exists()


def test_install_rejects_missing_binary_and_required_config(
    bundle: tuple[Path, dict[str, str]],
) -> None:
    work, env = bundle
    (work / "dist" / "vnc_worker").unlink()
    assert run(bundle, "install").returncode == 2
    (work / "dist" / "vnc_worker").write_text("#!/bin/sh\nexit 0\n")
    (work / "dist" / "vnc_worker").chmod(0o755)
    config = work / "vnc-worker.env"
    config.write_text(config.read_text().replace("VNC_WORKER_ID=192.168.10.21\n", ""))
    assert run(bundle, "install").returncode == 2
    assert not Path(env["VNC_BUILDER_UNIT_FILE"]).exists()


def test_service_is_root_binary_unit_without_removed_settings(
    bundle: tuple[Path, dict[str, str]],
) -> None:
    assert run(bundle, "install").returncode == 0
    _, env = bundle
    unit = Path(env["VNC_BUILDER_UNIT_FILE"]).read_text()
    config = Path(env["VNC_BUILDER_CONFIG_FILE"]).read_text()
    assert "User=root" in unit
    assert "EnvironmentFile=" in unit
    assert "ExecStart=" in unit and "vnc_worker run" in unit
    assert "VNC_INTERNAL_TOKEN" not in config
    assert "VNC_MODE" not in config
    assert "VNC_LEASE_SECONDS" not in config
