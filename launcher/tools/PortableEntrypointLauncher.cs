using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

internal static class PortableEntrypointLauncher
{
    private static string QuoteArgument(string value)
    {
        if (value == null)
        {
            return "\"\"";
        }

        if (value.Length > 0 &&
            value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            return value;
        }

        var result = new StringBuilder();
        result.Append('"');
        var backslashes = 0;
        foreach (var character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }

            if (character == '"')
            {
                result.Append('\\', (backslashes * 2) + 1);
                result.Append('"');
                backslashes = 0;
                continue;
            }

            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(character);
        }

        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private static string BuildArguments(
        string dispatcherPath,
        string scriptPath,
        string entrypointPath,
        string[] forwardedArguments)
    {
        var arguments = new List<string>
        {
            "-s",
            "-B",
            QuoteArgument(dispatcherPath),
            QuoteArgument(scriptPath),
            QuoteArgument(entrypointPath)
        };
        foreach (var argument in forwardedArguments)
        {
            arguments.Add(QuoteArgument(argument));
        }

        return string.Join(" ", arguments.ToArray());
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            var entrypointPath = Assembly.GetEntryAssembly().Location;
            var scriptsDirectory = Path.GetDirectoryName(entrypointPath);
            if (string.IsNullOrWhiteSpace(scriptsDirectory))
            {
                throw new InvalidOperationException("Unable to locate the Scripts directory.");
            }

            var environmentDirectory = Path.GetFullPath(
                Path.Combine(scriptsDirectory, ".."));
            var pythonPath = Path.Combine(environmentDirectory, "python.exe");
            var portableDirectory = Path.Combine(scriptsDirectory, ".portable");
            var dispatcherPath = Path.Combine(
                portableDirectory,
                "portable_entrypoint_dispatcher.py");
            var scriptPath = Path.Combine(
                portableDirectory,
                Path.GetFileNameWithoutExtension(entrypointPath) + ".py");

            foreach (var requiredPath in new[]
            {
                pythonPath,
                dispatcherPath,
                scriptPath
            })
            {
                if (!File.Exists(requiredPath))
                {
                    throw new FileNotFoundException(
                        "Portable Python entrypoint component is missing.",
                        requiredPath);
                }
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = pythonPath,
                Arguments = BuildArguments(
                    dispatcherPath,
                    scriptPath,
                    entrypointPath,
                    args),
                UseShellExecute = false,
                WorkingDirectory = Environment.CurrentDirectory
            };
            startInfo.EnvironmentVariables["PYTHONNOUSERSITE"] = "1";

            using (var process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException(
                        "The bundled Python process could not be started.");
                }

                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "Portable Python entrypoint failed: " + exception.Message);
            return 9009;
        }
    }
}
