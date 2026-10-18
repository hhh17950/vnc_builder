# GNOME xstartup 替换说明

模板为 `xstartup.example`，实际安装文件为目标用户的 `~/.vnc/xstartup`（文件名没有前导点）。安装器不会覆盖用户已有的桌面配置。

## 替换步骤

1. 等待正在执行的任务结束，然后停止 Worker：`sudo systemctl stop vnc-worker`。维护期间保持 Worker 停止，避免定时恢复与手工操作冲突。
2. 以桌面用户（例如 `snskap`）登录，在安装包目录执行：

   ```bash
   cp -p ~/.vnc/xstartup ~/.vnc/xstartup.bak
   cp xstartup.example ~/.vnc/xstartup
   vi ~/.vnc/xstartup
   chmod 755 ~/.vnc/xstartup
   bash -n ~/.vnc/xstartup
   ```

   如果原脚本使用自定义 `OPENBOX_DIR`，将原来的真实路径填回模板；留空会使用系统 XDG 目录。目录变量不会启动 Openbox。保留原文件备份，不需要递归修改 `.vnc` 的权限。

3. 同一用户先重建一个桌面：

   ```bash
   bash /opt/scripts/vnc_manager.sh stop :1
   bash /opt/scripts/vnc_manager.sh create -n 1
   ```

4. 连接 `:1`，确认 GNOME 能显示、窗口可操作。在桌面终端运行 `/opt/VirtualGL/bin/vglrun /usr/bin/nautilus`，确认关闭文件管理器后 GNOME 仍保持运行。若启动失败，查看 `~/.vnc/` 对应桌面的日志。
5. 单桌面正常后，重建其余桌面并验证四桌面并行；全部正常后执行 `sudo systemctl start vnc-worker`。修改 xstartup 不会自动作用于已经运行的桌面。

## 改动与验证边界

原脚本会在 Nautilus 命令返回后执行 `kill "$PID"` 结束 GNOME。模板改用前台 `dbus-launch ... gnome-session`，不再用文件管理器控制桌面寿命。独立 D-Bus 会话不等于 GNOME 所有用户级资源都已隔离，同账号四个 GNOME 桌面仍需要内网验证。

`xset` 只关闭 X11 层屏保和 DPMS。GNOME 锁屏、自动空闲和电源策略应在部署阶段统一关闭；模板不在运行期执行 `gsettings`，也不使用固定 sleep 来承诺防锁屏。`xset q` 成功只能证明 X11 可连接，不能证明 GNOME 可操作或未锁屏。

VirtualGL 路径变量保留，但 GNOME 本身没有新增 `vglrun` 包裹。是否加速 GNOME 应单独验证，不与本次会话生命周期修复一起调整。

回退时先停止 Worker，以桌面用户执行 `cp -p ~/.vnc/xstartup.bak ~/.vnc/xstartup`，再重建受影响的桌面。

参考：[D-Bus 启动说明](https://dbus.freedesktop.org/doc/dbus-launch.1.html)、[TurboVNC GNOME 兼容性说明](https://turbovnc.org/Documentation/Compatibility30)。
