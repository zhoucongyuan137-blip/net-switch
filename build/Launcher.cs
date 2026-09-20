// net-switch.exe 启动器
//
// 目标：既能当命令行工具用（有输出、有退出码、终端会等待），
//       又能在计划任务/双击时完全不出现窗口。
//
// 做法：
//  1) 编译为控制台子系统（/target:exe）—— 这样从终端运行时输出/退出码都正常；
//  2) 启动时检查控制台是不是"我们自己创建的"（GetConsoleProcessList 只有本进程）：
//     是 -> 说明是计划任务/双击拉起的，立刻 SW_HIDE 把自己的控制台窗口藏掉；
//     否 -> 说明是终端里运行的，保持原样，输出照常可见。
//  3) 子进程 powershell.exe 用 CreateNoWindow + 重定向 stdout/stderr，再原样转发出来，
//     这样管不管道、有没有控制台，输出都不会丢。
//
// 目录约定（用环境变量传给脚本）：
//   NETSWITCH_HOME       = exe 所在目录（脚本写日志/状态）
//   NETSWITCH_SCRIPT_DIR = 脚本释放目录（脚本之间互相调用）
//   NETSWITCH_EXE        = 本 exe 完整路径（自提权、注册计划任务）
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

[assembly: AssemblyTitle("net-switch")]
[assembly: AssemblyProduct("net-switch")]
[assembly: AssemblyDescription("校园网/手机热点双网卡自动选路 + 校园网自助认证")]
[assembly: AssemblyCompany("zhoucongyuan137-blip")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

static class Program
{
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] private static extern uint GetConsoleProcessList(uint[] list, uint count);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    private const int SW_HIDE = 0;

    private static readonly string[] Scripts = { "net-switch.ps1", "campus-login.ps1" };

    private static int Main(string[] rawArgs)
    {
        HideOwnConsole();

        string exePath   = Assembly.GetExecutingAssembly().Location;
        string exeDir    = Path.GetDirectoryName(exePath);
        string ver       = Assembly.GetExecutingAssembly().GetName().Version.ToString();
        string scriptDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "net-switch", "bin", ver);

        try
        {
            Directory.CreateDirectory(scriptDir);
            foreach (string name in Scripts) ExtractIfChanged(name, Path.Combine(scriptDir, name));
        }
        catch (Exception ex) { WriteErr("释放内嵌脚本失败: " + ex.Message); return 90; }

        Environment.SetEnvironmentVariable("NETSWITCH_HOME", exeDir);
        Environment.SetEnvironmentVariable("NETSWITCH_SCRIPT_DIR", scriptDir);
        Environment.SetEnvironmentVariable("NETSWITCH_EXE", exePath);

        var args = new List<string>(rawArgs);
        string script = "net-switch.ps1";
        if (args.Count == 0)
        {
            script = "campus-login.ps1";                 // 双击/无参数 = 打开设置界面
            args.Add("-Mode"); args.Add("gui");
        }
        else
        {
            for (int i = 0; i + 1 < args.Count; i++)
                if (args[i].Equals("-Mode", StringComparison.OrdinalIgnoreCase))
                {
                    string m = args[i + 1].ToLowerInvariant();
                    if (m == "gui" || m == "login" || m == "forget") script = "campus-login.ps1";
                }
        }

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File \""
                        + Path.Combine(scriptDir, script) + "\" " + Join(args),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = exeDir
            // 注意：不要设 StandardOutputEncoding=UTF8 —— 子进程按控制台代码页（中文 Windows = GBK）
            // 输出，强转 UTF-8 会把中文变成问号。用默认编码做"字节透传"最安全。
        };

        try
        {
            using (Process p = new Process { StartInfo = psi })
            {
                var outBuf = new StringBuilder();
                p.OutputDataReceived += (s, e) => { if (e.Data != null) Emit(e.Data); };
                p.ErrorDataReceived  += (s, e) => { if (e.Data != null) WriteErr(e.Data); };
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex) { WriteErr("启动 PowerShell 失败: " + ex.Message); return 91; }
    }

    /// <summary>计划任务/双击拉起时，把自己创建的控制台窗口藏掉；终端里运行则保留。</summary>
    private static void HideOwnConsole()
    {
        try
        {
            IntPtr h = GetConsoleWindow();
            if (h == IntPtr.Zero) return;                       // 本来就没有控制台
            var list = new uint[4];
            uint n = GetConsoleProcessList(list, (uint)list.Length);
            if (n <= 1) ShowWindow(h, SW_HIDE);                 // 只有自己 = 窗口是自己创建的
        }
        catch { }
    }

    private static void Emit(string s)
    {
        try { Console.Out.WriteLine(s); Console.Out.Flush(); } catch { }
    }

    private static void WriteErr(string s)
    {
        try { Console.Error.WriteLine(s); Console.Error.Flush(); } catch { }
    }

    private static string Join(List<string> a)
    {
        var sb = new StringBuilder();
        foreach (string s in a) { if (sb.Length > 0) sb.Append(' '); sb.Append(Quote(s)); }
        return sb.ToString();
    }

    private static string Quote(string s)
    {
        if (s.Length == 0) return "\"\"";
        if (s.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return s;
        return "\"" + s.Replace("\"", "\\\"") + "\"";
    }

    private static void ExtractIfChanged(string name, string outPath)
    {
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream s = asm.GetManifestResourceStream(name))
        {
            if (s == null) throw new Exception("内嵌资源缺失: " + name);
            byte[] data = new byte[s.Length];
            int read = 0;
            while (read < data.Length)
            {
                int n = s.Read(data, read, data.Length - read);
                if (n <= 0) break;
                read += n;
            }
            if (File.Exists(outPath))
            {
                byte[] old = File.ReadAllBytes(outPath);
                if (old.Length == data.Length)
                {
                    bool same = true;
                    for (int i = 0; i < data.Length; i++) if (old[i] != data[i]) { same = false; break; }
                    if (same) return;
                }
            }
            File.WriteAllBytes(outPath, data);
        }
    }
}
