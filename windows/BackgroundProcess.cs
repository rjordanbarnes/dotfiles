using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

internal static class BackgroundProcess
{
    private static int Main(string[] args)
    {
        if (args.Length == 0)
            return 64;

        try
        {
            bool proxyStdio = args[0] == "--proxy-stdio";
            int commandIndex = proxyStdio ? 1 : 0;
            if (commandIndex >= args.Length)
                return 64;

            var arguments = new List<string>();
            for (int i = commandIndex + 1; i < args.Length; i++)
                arguments.Add(QuoteArgument(args[i]));

            var startInfo = new ProcessStartInfo
            {
                FileName = Path.GetFullPath(args[commandIndex]),
                Arguments = string.Join(" ", arguments),
                WorkingDirectory = Environment.CurrentDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = proxyStdio,
                RedirectStandardOutput = proxyStdio,
                RedirectStandardError = proxyStdio
            };

            using (var process = Process.Start(startInfo))
            {
                if (proxyStdio)
                    return ProxyStdio(process);

                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            try
            {
                File.AppendAllText(
                    Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "launcher.log"),
                    DateTimeOffset.Now.ToString("o") + " " + error.Message + Environment.NewLine);
            }
            catch (Exception)
            {
            }

            return 1;
        }
    }

    private static int ProxyStdio(Process process)
    {
        Stream parentInput = Console.OpenStandardInput();
        Stream parentOutput = Console.OpenStandardOutput();
        Stream parentError = Console.OpenStandardError();
        Stream childInput = process.StandardInput.BaseStream;

        Task input = parentInput.CopyToAsync(childInput);
        input.ContinueWith(
            delegate(Task completed)
            {
                if (completed.IsFaulted)
                {
                    var ignored = completed.Exception;
                }

                try
                {
                    childInput.Close();
                }
                catch (Exception)
                {
                }
            },
            TaskScheduler.Default);

        Task output = process.StandardOutput.BaseStream.CopyToAsync(parentOutput);
        Task error = process.StandardError.BaseStream.CopyToAsync(parentError);

        process.WaitForExit();
        try
        {
            childInput.Close();
        }
        catch (Exception)
        {
        }
        try
        {
            parentInput.Close();
        }
        catch (Exception)
        {
        }

        Task.WaitAll(output, error);
        parentOutput.Flush();
        parentError.Flush();
        return process.ExitCode;
    }

    private static string QuoteArgument(string value)
    {
        var result = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }

            result.Append('\\', character == '"' ? backslashes * 2 + 1 : backslashes);
            result.Append(character);
            backslashes = 0;
        }

        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }
}
