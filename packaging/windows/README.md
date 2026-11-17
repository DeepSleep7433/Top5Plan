# Windows 安装包构建

`stage-release.ps1` 从 `client/build/windows/x64/runner/Release` 复制运行文件，
加入 app-local VC++ 运行库，生成便携 ZIP，然后调用 Inno Setup 编译器生成
per-user EXE 安装包。

要求：

- Flutter Windows Release 已构建；
- Visual Studio VC++ Redist 目录存在；
- Inno Setup 6.x，默认路径 `E:\Tools\InnoSetup\ISCC.exe` 或设置
  `INNO_SETUP_ISCC`。

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\stage-release.ps1
```

该安装包是测试构建，未使用生产代码签名证书，Windows SmartScreen 可能提示
未知发布者。它与 MSIX 的部署信任机制独立；安装位置默认为
`%LOCALAPPDATA%\Programs\T5`，卸载不会删除 `%APPDATA%\com.t5plan` 下的业务数据。
