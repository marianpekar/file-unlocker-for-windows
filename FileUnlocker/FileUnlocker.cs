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
            Process[] processes = path.Exist() && path.IsDirectoryPath() ? GetProcessesFromDirectoryPath(path) : GetProcessesFromFilePath(path);

            if (IsProcessArrayEmpty(processes, path, silent)) return;

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
            string[] filePaths = Directory.GetFiles(directoryPath, string.Empty, SearchOption.AllDirectories);
            List<Process> processes = new List<Process>();

            foreach (string path in filePaths)
            {
                processes.AddRange(RestartManager.GetProcesses(path));
            }

            return processes.ToArray();
        }

        private static Process[] GetProcessesFromFilePath(string filePath)
        {
            return RestartManager.GetProcesses(filePath).ToArray();
        }

        private static void ShowDialog(string path, Process[] processes)
        {
            StringBuilder stringBuilder = new StringBuilder();
            stringBuilder.AppendLine($"{Path.GetFileName(path)} is locked by:");

            foreach (Process process in processes)
            {
                stringBuilder.AppendLine($"{process.ProcessName} ({process.Id})");
            }
            stringBuilder.AppendLine($"Kill {(processes.Length > 1 ? "processes" : "process")}?");

            Message.ShowYesNoDialog(stringBuilder.ToString(), "Unlock", KillProcesses, null, processes);
        }

        private static void KillProcesses(Process[] processes)
        {
            foreach (Process process in processes)
            {
                process.Kill(true);
            }
        }
        private static bool IsProcessArrayEmpty(Process[] processes, string path, bool silent)
        {
            if (processes.Length == 0)
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
