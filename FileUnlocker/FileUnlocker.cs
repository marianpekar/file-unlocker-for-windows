using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace FileUnlocker
{
    public static class FileUnlocker
    {
        public static void Unlock(string path, bool silent)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                if (!silent)
                {
                    Message.Show("No file or directory path was provided.", "Unlock");
                }
                return;
            }

            var processes = path.Exist() && path.IsDirectoryPath()
                ? GetProcessesFromDirectoryPath(path)
                : GetProcessesFromFilePath(path);

            if (IsProcessArrayEmpty(processes, path, silent))
            {
                return;
            }

            if (silent)
            {
                KillProcesses(processes);
            }
            else
            {
                ShowDialog(path, processes);
            }
        }

        private static Process[] GetProcessesFromDirectoryPath(string directoryPath)
        {
            string[] filePaths = Directory.GetFiles(directoryPath, "*", SearchOption.AllDirectories);

            var processesById = new Dictionary<int, Process>();

            foreach (string path in filePaths)
            {
                foreach (var process in RestartManager.GetProcesses(path))
                {
                    if (!processesById.ContainsKey(process.Id))
                    {
                        processesById[process.Id] = process;
                    }
                }
            }

            return new List<Process>(processesById.Values).ToArray();
        }

        private static Process[] GetProcessesFromFilePath(string filePath)
        {
            var processesById = new Dictionary<int, Process>();

            foreach (var process in RestartManager.GetProcesses(filePath))
            {
                if (!processesById.ContainsKey(process.Id))
                {
                    processesById[process.Id] = process;
                }
            }

            return new List<Process>(processesById.Values).ToArray();
        }

        private static void ShowDialog(string path, Process[] processes)
        {
            var sb = new StringBuilder();
            sb.AppendLine($"{Path.GetFileName(path)} is locked by:");

            foreach (Process process in processes)
            {
                sb.AppendLine($"{process.ProcessName} ({process.Id})");
            }

            sb.AppendLine($"Kill {(processes.Length > 1 ? "processes" : "process")}?");

            Message.ShowYesNoDialog(sb.ToString(), "Unlock", KillProcesses, null, processes);
        }

        private static void KillProcesses(Process[] processes)
        {
            foreach (Process process in processes)
            {
                try
                {
                    if (process.HasExited)
                    {
                        continue;
                    }

                    process.Kill(entireProcessTree: true);

                    process.WaitForExit(2000);
                }
                catch (Exception ex) when (ex is InvalidOperationException || ex is System.ComponentModel.Win32Exception)
                {
                }
                finally
                {
                    process.Dispose();
                }
            }
        }

        private static bool IsProcessArrayEmpty(Process[] processes, string path, bool silent)
        {
            if (processes == null || processes.Length == 0)
            {
                if (!silent)
                {
                    Message.Show($"{Path.GetFileName(path)} is not currently locked by any process.", "Unlock");
                }

                return true;
            }

            return false;
        }
    }
}
