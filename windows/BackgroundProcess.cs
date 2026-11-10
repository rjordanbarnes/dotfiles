using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class BackgroundProcess
{
    private static int Main(string[] args)
    {
        if (args.Length == 0)
            return 64;

        try
        {
            var arguments = new List<string>();
            for (int i = 1; i < args.Length; i++)
                arguments.Add(QuoteArgument(args[i]));

            var startInfo = new ProcessStartInfo
            {
                FileName = Path.GetFullPath(args[0]),
                Arguments = string.Join(" ", arguments),
                WorkingDirectory = Environment.CurrentDirectory,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using (var process = Process.Start(startInfo))
            {
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
