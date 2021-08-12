using System;
using System.Text;
using System.IO;
using System.Diagnostics;

namespace FileUnlocker
{
    class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            string path = args[0];
            Process[] processes = RestartManager.GetProcesses(path).ToArray();

            if (processes.Length == 0)
            {
                Message.Show($"No process is currently locking {Path.GetFileName(path)}", "Unlock");
                return;
            }

            ShowDialog(path, processes);
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

            Message.ShowYesNoDialog(stringBuilder.ToString(), "Unlock", KillProcesses , null, processes);
        }

        private static void KillProcesses(Process[] processes)
        {
            foreach (Process process in processes)
            {
                process.Kill(true);
            }
        }
    }
}
