# 小狼毫程序替换包

适用于已安装小狼毫的 x64 Windows。完整包包含服务、部署和安装程序、32/64 位 TSF、
Rime 和 WinSparkle；源目录有旧版 `.ime`、7-Zip、curl 程序时也会收录。实际内容见 `manifest.json`。
本包不包含个人配置、词库或背景图片，不能作为全新安装包使用。程序文件必须来自兼容的一套构建。
目标机器自己的卸载程序保留在原处。

## 安装

1. 解压整个 ZIP 到本机目录。
2. 双击 `Install.cmd`，在 Windows 权限提示中确认管理员权限。
3. 等待看到 `SCHEDULED` 和备份路径，保存工作后重启 Windows。
4. 双击 `Verify.cmd`；所有路径均显示 `MATCH` 表示文件版本一致。

默认在 Windows 重启时替换，避免正在运行的程序占用 DLL。不会自动重启或终止应用。
除安装目录外，还会更新实际注册的 System32、SysWOW64 中的 TSF DLL。
完整包的旧版 `.ime` 文件只替换安装目录副本，不修改旧 IMM 的系统注册或系统文件。
每次操作都会检查文件清单、架构和 SHA256，再备份全部目标文件。

安装路径会从注册表检测。自定义路径或命令行使用：

```powershell
# 只读预览，不提权、不复制文件
.\Replace-Weasel.ps1 -InstallDir 'C:\Program Files\Rime\weasel-0.17.4' -WhatIf
# 安排重启替换（申请管理员权限）
.\Replace-Weasel.ps1 -InstallDir 'C:\Program Files\Rime\weasel-0.17.4' -Elevate
# 已关闭占用程序时，可尝试立即替换；失败会尝试恢复原文件
.\Replace-Weasel.ps1 -Timing Immediate -Elevate
# 只读检查；退出码 0 为一致，2 为版本不同，1 为校验失败
.\Replace-Weasel.ps1 -Mode Verify
```

## 取消或恢复

备份位于安装目录的 `backup-replacement-日期-编号` 中。`backup.json` 记录每个目标的原始哈希、
备份文件和安装状态；请选择需要返回的那次备份，不能默认认为最新备份就是最初版本。

```powershell
# 重启前取消本次安排；保留其他软件的重启操作
.\Replace-Weasel.ps1 -Mode CancelPending -BackupDir '实际备份目录' -Elevate
# 重启安装后，从指定备份恢复；当前版本也会先备份，然后安排下次重启恢复
.\Replace-Weasel.ps1 -Mode Restore -BackupDir '实际备份目录' -Elevate
```

如有尚未执行的冲突替换，先取消对应安排或完成重启，再进行下一次替换/恢复。
取消安排不会撤销已执行的替换。此工具仅识别自身生成的 `backup.json`，不读取旧临时安装器的备份格式。

包内 SHA256 用于发现损坏和版本不一致，不是发布者签名。
重新打包只复制明确选择的程序文件，不负责编译；文件版本、修改时间和内容哈希会记录在清单中。
源码与构建说明应随修改版的公开分发一起提供，许可见 `LICENSE.txt`。
