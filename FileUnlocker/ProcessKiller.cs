using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace FileUnlocker
{
    /// <summary>One process that could not be closed, with the reason.</summary>
    public sealed class KillFailure
    {
        public KillFailure(LockingProcess process, string reason)
        {
            Process = process;
            Reason = reason;
        }

        public LockingProcess Process { get; }

        public string Reason { get; }

        /// <summary>Output line: <c>name (pid): reason</c>.</summary>
        public string Describe()
        {
            return $"{Process.GetDisplayName()} ({Process.ProcessId}): {Reason}";
        }
    }

    /// <summary>Outcome of one kill attempt over a set of processes.</summary>
    public sealed class KillResult
    {
        public KillResult(
            IReadOnlyList<LockingProcess> killed,
            IReadOnlyList<KillFailure> failed,
            IReadOnlyList<LockingProcess> skipped)
        {
            Killed = killed;
            Failed = failed;
            Skipped = skipped;
        }

        /// <summary>Processes that are gone now.</summary>
        public IReadOnlyList<LockingProcess> Killed { get; }

        /// <summary>Processes that were asked to close but are still running.</summary>
        public IReadOnlyList<KillFailure> Failed { get; }

        /// <summary>Protected system processes that were deliberately left alone.</summary>
        public IReadOnlyList<LockingProcess> Skipped { get; }

        /// <summary>True when at least one process was asked to close.</summary>
        public bool Attempted => Killed.Count > 0 || Failed.Count > 0;
    }

    /// <summary>
    /// Closes the locking processes.
    /// <para>
    /// A process that was already gone counts as closed, not as a failure: the goal is
    /// to have the file free, not to have performed a kill. Protected system processes
    /// are never touched.
    /// </para>
    /// </summary>
    public static class ProcessKiller
    {
        private const int ExitWaitMilliseconds = 3000;

        /// <summary>Closes every process in <paramref name="processes"/> except protected ones.</summary>
        public static KillResult Kill(IReadOnlyList<LockingProcess> processes)
        {
            var killed = new List<LockingProcess>();
            var failed = new List<KillFailure>();
            var skipped = new List<LockingProcess>();

            foreach (LockingProcess locking in processes ?? Array.Empty<LockingProcess>())
            {
                if (locking.IsProtected)
                {
                    skipped.Add(locking);
                    continue;
                }

                string reason = TryKill(locking);

                if (reason == null)
                {
                    killed.Add(locking);
                }
                else
                {
                    failed.Add(new KillFailure(locking, reason));
                }
            }

            return new KillResult(killed, failed, skipped);
        }

        /// <summary>Returns null on success, otherwise the reason the process is still running.</summary>
        private static string TryKill(LockingProcess locking)
        {
            Process process = null;

            try
            {
                try
                {
                    process = Process.GetProcessById(locking.ProcessId);
                }
                catch (ArgumentException)
                {
                    // It is already gone, which is what we wanted.
                    return null;
                }

                if (process.HasExited)
                {
                    return null;
                }

                try
                {
                    // Closing the whole tree stops children that also hold the file.
                    process.Kill(entireProcessTree: true);
                }
                catch (Exception ex) when (IsKillFailure(ex))
                {
                    // The tree walk can fail for a child that already exited, or a
                    // platform quirk can reject the overload. Fall back to the process.
                    TryPlainKill(process, locking);
                }

                process.WaitForExit(ExitWaitMilliseconds);

                return process.HasExited ? null : "did not exit";
            }
            catch (Exception ex)
            {
                return ex.Message;
            }
            finally
            {
                process?.Dispose();
            }
        }

        private static void TryPlainKill(Process process, LockingProcess locking)
        {
            try
            {
                if (process.HasExited)
                {
                    return;
                }

                process.Kill();
            }
            catch (Exception ex) when (IsKillFailure(ex))
            {
                // Reported below through HasExited; a process that vanished is fine.
                _ = ex;
                _ = locking;
            }
        }

        private static bool IsKillFailure(Exception ex)
        {
            return ex is System.ComponentModel.Win32Exception ||
                   ex is InvalidOperationException ||
                   ex is AggregateException ||
                   ex is NotSupportedException ||
                   ex is ArgumentException;
        }

        /// <summary>
        /// Every process that is still running with the same identity, after a kill
        /// attempt. Used to decide between "unlocked" and "still locked".
        /// </summary>
        public static List<LockingProcess> FilterStillRunning(IReadOnlyList<LockingProcess> processes)
        {
            return (processes ?? Array.Empty<LockingProcess>()).Where(p => p.IsRunning()).ToList();
        }
    }
}
