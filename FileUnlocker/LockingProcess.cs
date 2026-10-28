using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices.ComTypes;

namespace FileUnlocker
{
    /// <summary>
    /// One process reported by the Restart Manager as using the item.
    /// <para>
    /// This is a plain data model. It deliberately holds no <see cref="Process"/>
    /// handle, so it stays valid after the process dies and cannot leak a handle.
    /// </para>
    /// </summary>
    public sealed class LockingProcess
    {
        /// <summary>Process id reported by the Restart Manager.</summary>
        public int ProcessId { get; set; }

        /// <summary>
        /// Process start time from the Restart Manager. Together with the id this
        /// identifies one process incarnation, so a recycled PID is not confused
        /// with the original process.
        /// </summary>
        public long StartTime { get; set; }

        /// <summary>Name reported by the operating system, without the ".exe" suffix.</summary>
        public string ProcessName { get; set; }

        /// <summary>Friendly application name reported by the Restart Manager.</summary>
        public string AppName { get; set; }

        /// <summary>Service short name, empty for a normal process.</summary>
        public string ServiceShortName { get; set; }

        /// <summary>Restart Manager application type.</summary>
        public AppType AppType { get; set; }

        /// <summary>True when the Restart Manager says the process can be restarted.</summary>
        public bool Restartable { get; set; }

        private static readonly string[] ProtectedNames =
        {
            "System",
            "Idle",
            "Registry",
            "Memory Compression",
            "Secure System",
            "smss",
            "csrss",
            "wininit",
            "services",
            "lsass",
            "winlogon",
            "fontdrvhost",
            "dwm",
            "LogonUI",
        };

        private static readonly string[] WarningNames =
        {
            "explorer",
            "StartMenuExperienceHost",
            "ShellExperienceHost",
            "SearchHost",
            "TextInputHost",
        };

        /// <summary>
        /// True for processes that must never be killed: the kernel and session
        /// manager processes. Closing them would crash or log out the machine.
        /// </summary>
        public bool IsProtected =>
            ProcessId == 0 ||
            ProcessId == 4 ||
            (!string.IsNullOrEmpty(ProcessName) &&
             ProcessName.EqualsAny(StringComparison.OrdinalIgnoreCase, ProtectedNames));

        /// <summary>
        /// True for processes that are closed but are shell or critical processes.
        /// They are reported as <c>[critical]</c> and called out in the dialog because
        /// closing them closes the desktop shell or loses unsaved work.
        /// </summary>
        public bool NeedsWarning =>
            AppType == AppType.Critical ||
            (!string.IsNullOrEmpty(ProcessName) &&
             ProcessName.EqualsAny(StringComparison.OrdinalIgnoreCase, WarningNames));

        /// <summary>
        /// Name shown to the user: the operating system process name when known,
        /// otherwise the Restart Manager application name, otherwise the process id.
        /// </summary>
        public string GetDisplayName()
        {
            if (!string.IsNullOrWhiteSpace(ProcessName))
            {
                return ProcessName;
            }

            if (!string.IsNullOrWhiteSpace(AppName))
            {
                return AppName;
            }

            return $"process {ProcessId}";
        }

        /// <summary>
        /// True when the process is still running with the same identity.
        /// <para>
        /// The comparison is deliberately against <see cref="Process.StartTime"/>'s
        /// <c>ToFileTime()</c> and not against its <c>Ticks</c> property. The two use
        /// different epochs: FILETIME counts 100 ns units from 1601-01-01, while
        /// <c>DateTime.Ticks</c> counts from 0001-01-01. <see cref="StartTime"/> holds
        /// the raw FILETIME value, so comparing it with <c>Ticks</c> can never be equal
        /// and would make every process look as if it had exited.
        /// </para>
        /// <para>
        /// Do not use <c>ToUniversalTime()</c> here: a FILETIME is already UTC, and
        /// converting the DateTime to UTC does not produce the same basis.
        /// </para>
        /// </summary>
        public bool IsRunning()
        {
            try
            {
                using (Process process = Process.GetProcessById(ProcessId))
                {
                    return process.StartTime.ToFileTime() == StartTime;
                }
            }
            catch (ArgumentException)
            {
                return false;
            }
            catch (InvalidOperationException)
            {
                return false;
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // The process exists but cannot be inspected. Assume it is still there.
                return true;
            }
        }

        /// <summary>
        /// One output line: <c>  name (pid)</c> with <c> [critical]</c> appended when
        /// the process is classified as critical.
        /// </summary>
        public string Describe()
        {
            string line = $"{GetDisplayName()} ({ProcessId})";

            if (NeedsWarning)
            {
                line += " [critical]";
            }

            return line;
        }

        /// <summary>
        /// Converts a Restart Manager start time to ticks so two incarnations of the
        /// same process id can be told apart.
        /// </summary>
        public static long StartTimeFromFileTime(FILETIME fileTime)
        {
            long ticks = ((long)fileTime.dwHighDateTime << 32) | (uint)fileTime.dwLowDateTime;
            return ticks;
        }

        /// <summary>
        /// Removes duplicates by (pid, start time) and drops the given process id.
        /// </summary>
        public static List<LockingProcess> Deduplicate(IEnumerable<LockingProcess> processes, int excludeProcessId)
        {
            var result = new List<LockingProcess>();
            var seen = new HashSet<string>(StringComparer.Ordinal);

            foreach (LockingProcess process in processes ?? Enumerable.Empty<LockingProcess>())
            {
                if (process.ProcessId == excludeProcessId)
                {
                    continue;
                }

                string key = process.ProcessId.ToString() + ":" + process.StartTime.ToString();
                if (seen.Add(key))
                {
                    result.Add(process);
                }
            }

            return result;
        }
    }
}
