using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("ComfyUI 桌面版")]
[assembly: AssemblyDescription("Portable ComfyUI desktop launcher")]
[assembly: AssemblyCompany("ComfyUI Desktop Package")]
[assembly: AssemblyProduct("ComfyUI 桌面版")]
[assembly: AssemblyVersion("1.3.3.0")]
[assembly: AssemblyFileVersion("1.3.3.0")]

internal static class PortableLauncher
{
    private static string GetBootstrapLogPath(string root)
    {
        string logDirectory = Path.Combine(root, "user", "launcher", "logs");
        Directory.CreateDirectory(logDirectory);
        return Path.Combine(logDirectory, "bootstrap.log");
    }

    private static string ReadLogTail(string path, int maximumCharacters)
    {
        try
        {
            if (!File.Exists(path))
            {
                return "";
            }
            string text = File.ReadAllText(path, Encoding.UTF8).Trim();
            if (text.Length > maximumCharacters)
            {
                text = text.Substring(text.Length - maximumCharacters);
            }
            return text;
        }
        catch
        {
            return "";
        }
    }

    private static void WriteBootstrapFailure(string root, Exception exception)
    {
        try
        {
            string logPath = GetBootstrapLogPath(root);
            File.AppendAllText(
                logPath,
                "[" + DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss zzz") + "] " +
                exception.ToString() + Environment.NewLine,
                new System.Text.UTF8Encoding(false));
        }
        catch
        {
        }
    }

    [STAThread]
    private static void Main()
    {
        string root = "";
        try
        {
            string executablePath = Assembly.GetExecutingAssembly().Location;
            root = Path.GetDirectoryName(executablePath);
            if (String.IsNullOrEmpty(root))
            {
                throw new InvalidOperationException("无法确定整合包所在目录。");
            }

            string launcherScript = Path.Combine(root, "tools", "ComfyUI-Launcher.ps1");
            string pythonPath = Path.Combine(root, ".ext", "python.exe");
            string mainPath = Path.Combine(root, "main.py");

            string[] requiredFiles = new string[]
            {
                launcherScript,
                pythonPath,
                mainPath,
                Path.Combine(root, "tools", "ComfyUI-Launcher.xaml"),
                Path.Combine(root, "tools", "ComfyUI-Launcher.Services.psm1"),
                Path.Combine(root, "tools", "ComfyUI-Core-Updater.ps1"),
                Path.Combine(root, "tools", "ComfyUI-Extension-Worker.ps1"),
                Path.Combine(root, "tools", "launcher-version.json"),
                Path.Combine(root, "assets", "icons", "comfyui-taskbar-large.ico"),
                Path.Combine(root, "tools", "assets", "hero", "comfyui-hero-cover.jpg")
            };
            foreach (string requiredFile in requiredFiles)
            {
                if (!File.Exists(requiredFile))
                {
                    throw new FileNotFoundException(
                        "整合包文件不完整或被安全软件隔离：\r\n" +
                        requiredFile +
                        "\r\n\r\n请重新完整解压，不要在压缩包内直接运行。"
                    );
                }
            }

            string powershellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32",
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe"
            );
            if (!File.Exists(powershellPath))
            {
                powershellPath = "powershell.exe";
            }

            string bootstrapLogPath = GetBootstrapLogPath(root);
            File.AppendAllText(
                bootstrapLogPath,
                "[" + DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss zzz") +
                "] Starting launcher from " + root + Environment.NewLine,
                new UTF8Encoding(false));
            string escapedScript = launcherScript.Replace("'", "''");
            string escapedLog = bootstrapLogPath.Replace("'", "''");
            string bootstrapCommand =
                "$ErrorActionPreference='Stop'; try { & '" + escapedScript +
                "' } catch { ($_ | Out-String) | Add-Content -LiteralPath '" +
                escapedLog + "' -Encoding UTF8; exit 1 }";
            string encodedCommand = Convert.ToBase64String(
                Encoding.Unicode.GetBytes(bootstrapCommand));

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments =
                    "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass " +
                    "-WindowStyle Hidden -EncodedCommand " + encodedCommand,
                WorkingDirectory = root,
                // ShellExecute gives Windows PowerShell a valid hidden console
                // host.  CreateNoWindow can make ConsoleControl initialization
                // throw Win32Exception on some Windows 10/11 builds before WPF
                // has a chance to create the launcher window.
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            Process process = Process.Start(startInfo);
            if (process == null)
            {
                throw new InvalidOperationException("无法创建启动器进程。");
            }
            if (process.WaitForExit(3000))
            {
                string diagnostic = ReadLogTail(bootstrapLogPath, 1800);
                throw new InvalidOperationException(
                    "启动器进程过早退出，退出代码：" + process.ExitCode + "。" +
                    (String.IsNullOrWhiteSpace(diagnostic)
                        ? ""
                        : "\r\n\r\n诊断信息：\r\n" + diagnostic)
                );
            }
        }
        catch (Exception exception)
        {
            if (!String.IsNullOrEmpty(root))
            {
                WriteBootstrapFailure(root, exception);
            }
            MessageBox.Show(
                "ComfyUI 启动失败：\r\n\r\n" + exception.Message +
                "\r\n\r\n请尝试“启动_ComfyUI_备用.bat”，并将 " +
                "user\\launcher\\logs\\bootstrap.log 发给老师。",
                "ComfyUI 桌面版",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
            Environment.ExitCode = 1;
        }
    }
}
