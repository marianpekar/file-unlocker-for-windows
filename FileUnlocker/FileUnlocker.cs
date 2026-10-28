using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace FileUnlocker
{
    /// <summary>
    /// Orchestration: validate the path, find the locking processes, ask the user and
    /// close them. Every exit path returns one of the documented codes.
    /// </summary>
    public static class FileUnlocker
    {
        /// <summary>Options used when enumerating a folder.</summary>
        private static readonly EnumerationOptions FolderEnumeration = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.ReparsePoint,
            MaxRecursionDepth = 64,
            ReturnSpecialDirectories = false,
        };

        /// <summary>
        /// Runs one unlock operation and returns the process exit code.
        /// </summary>
        public static int Run(Options options)
        {
            if (options == null)
            {
                throw new ArgumentNullException(nameof(options));
            }

            string path = options.Path;
            string fullPath;

            // Validate before anything else. A bad path must never be reported as
            // "not locked": the Restart Manager happily returns zero processes for a
            // path that does not exist.
            try
            {
                fullPath = Path.GetFullPath(path);
            }
            catch (Exception ex) when (IsInvalidPath(ex))
            {
                Output.Error($"\"{path}\" is not a valid path.");
                return ExitCodes.NotFound;
            }

            if (!fullPath.Exist() || !IsAccessible(fullPath))
            {
                Output.Error($"\"{fullPath}\" does not exist or is not accessible.");
                return ExitCodes.NotFound;
            }

            // A drive root or a share root would make the tool walk an entire volume
            // and, in silent mode, close every process holding any file on it. One
            // comparison covers "/", "\", "//", "C:\" and "\\server\share".
            if (IsRootPath(fullPath))
            {
                Output.UsageError($"\"{fullPath}\" is a drive root; point at a file or a folder inside it instead.");
                return ExitCodes.Usage;
            }

            string display = fullPath.GetDisplayName();
            Output.Info($"unlocking {fullPath}");

            var files = new List<string>();

            if (fullPath.IsDirectoryPath())
            {
                files.AddRange(EnumerateFiles(fullPath, out bool truncated));

                if (files.Count == 0)
                {
                    Output.Info("note: the directory contains no files");
                }

                if (truncated)
                {
                    // The walk stopped early, so "nothing locked" may be wrong.
                    Output.Info("note: some folders could not be read; the result may be incomplete");
                }
            }
            else
            {
                files.Add(fullPath);
            }

            List<LockingProcess> processes;
            int registrationSkipped;

            using (var session = new RestartManagerSession())
            {
                processes = session.GetLockingProcesses(files, out registrationSkipped);
            }

            if (registrationSkipped > 0)
            {
                if (files.Count > 0 && registrationSkipped == files.Count)
                {
                    // Nothing at all was checked, so "nothing locked" would be a lie.
                    Output.Error($"\"{fullPath}\" could not be checked: the Restart Manager refused every file in it.");
                    return ExitCodes.NotFound;
                }

                Output.Info($"note: {registrationSkipped} file(s) could not be registered and were skipped");
            }

            processes = LockingProcess.Deduplicate(processes, Environment.ProcessId);

            if (processes.Count == 0)
            {
                Output.Info("result: nothing locked");

                if (!options.Silent)
                {
                    Message.ShowInfo($"\"{display}\" is not locked by any process.");
                }

                return ExitCodes.Success;
            }

            Output.Info($"{processes.Count} locking process(es)");

            foreach (LockingProcess process in processes)
            {
                Output.Line($"FileUnlocker:   {process.Describe()}");
            }

            if (!options.Silent && !Confirm(display, processes))
            {
                Output.Info("result: cancelled");
                return ExitCodes.Cancelled;
            }

            KillResult result = ProcessKiller.Kill(processes);

            foreach (LockingProcess process in result.Killed)
            {
                Output.Info($"killed {process.GetDisplayName()} ({process.ProcessId})");
            }

            foreach (KillFailure failure in result.Failed)
            {
                Output.Info($"failed {failure.Describe()}");
            }

            foreach (LockingProcess process in result.Skipped)
            {
                Output.Info($"skipped {process.GetDisplayName()} ({process.ProcessId}): protected system process");
            }

            // Only a real kill attempt can change the lock state, so rescan only then.
            List<LockingProcess> stillRunning = result.Attempted
                ? FilterStillLocking(files)
                : processes;

            int exitCode = DetermineExitCode(result, stillRunning);

            if (stillRunning.Count == 0)
            {
                Output.Info("result: unlocked");
            }
            else
            {
                Output.Info($"result: still locked ({stillRunning.Count} process(es))");
            }

            if (!options.Silent)
            {
                ShowResult(display, result, stillRunning);
            }

            return exitCode;
        }

        /// <summary>
        /// Maps the outcome to an exit code.
        /// <para>
        /// The item is free -> 0. Nothing was closed at all and every remaining
        /// process was deliberately left alone (a protected system process, or one
        /// that needs administrator rights) -> 3. Anything else that is still locked
        /// -> 4.
        /// </para>
        /// </summary>
        private static int DetermineExitCode(KillResult result, List<LockingProcess> stillRunning)
        {
            if (stillRunning.Count == 0)
            {
                return ExitCodes.Success;
            }

            bool nothingWasClosed = result.Killed.Count == 0 && result.Failed.Count == 0;

            return nothingWasClosed && result.Skipped.Count > 0
                ? ExitCodes.NothingClosed
                : ExitCodes.Partial;
        }

        /// <summary>
        /// Registers the files again to find out whether the item is really free now.
        /// The identity of each remaining process is re-checked, so a process that
        /// exited during the rescan is not reported as still locking the file.
        /// </summary>
        private static List<LockingProcess> FilterStillLocking(List<string> files)
        {
            try
            {
                List<LockingProcess> remaining;
                int skipped;

                using (var session = new RestartManagerSession())
                {
                    remaining = session.GetLockingProcesses(files, out skipped);
                }

                remaining = LockingProcess.Deduplicate(remaining, Environment.ProcessId);
                return ProcessKiller.FilterStillRunning(remaining);
            }
            catch (Exception ex)
            {
                // A failed rescan must not turn a successful unlock into a crash. The
                // kill results themselves already tell the story.
                Output.Error($"could not re-check the item: {ex.Message}");
                return new List<LockingProcess>();
            }
        }

        /// <summary>Builds and shows the confirmation dialog.</summary>
        private static bool Confirm(string display, List<LockingProcess> processes)
        {
            var sb = new StringBuilder();
            sb.AppendLine($"\"{display}\" is locked by {processes.Count} process(es):");
            sb.AppendLine();

            foreach (LockingProcess process in processes)
            {
                sb.AppendLine("    " + process.Describe());
            }

            bool warning = false;

            foreach (LockingProcess process in processes)
            {
                if (process.NeedsWarning)
                {
                    warning = true;
                    break;
                }
            }

            if (warning)
            {
                sb.AppendLine();
                sb.AppendLine("Warning: at least one of these is a system or critical process.");
                sb.AppendLine("Closing it closes the shell or the desktop, their unsaved work is lost,");
                sb.AppendLine("and child processes are closed too.");
            }

            sb.AppendLine();
            sb.Append("Close the process(es) above?");

            return Message.Confirm(sb.ToString());
        }

        /// <summary>Builds and shows the result dialog.</summary>
        private static void ShowResult(string display, KillResult result, List<LockingProcess> stillRunning)
        {
            var sb = new StringBuilder();
            int total = result.Killed.Count + result.Failed.Count;
            sb.AppendLine($"Closed {result.Killed.Count} of {total} process(es).");

            if (result.Skipped.Count > 0)
            {
                sb.AppendLine();

                foreach (LockingProcess process in result.Skipped)
                {
                    sb.AppendLine($"Skipped {process.Describe()}: protected system process.");
                }
            }

            if (result.Failed.Count > 0)
            {
                sb.AppendLine();

                foreach (KillFailure failure in result.Failed)
                {
                    sb.AppendLine($"Could not close {failure.Describe()}.");
                }
            }

            sb.AppendLine();

            if (stillRunning.Count == 0)
            {
                sb.Append($"\"{display}\" is no longer locked.");
            }
            else
            {
                sb.Append($"\"{display}\" is still locked by {stillRunning.Count} process(es). ");
                sb.Append("Try running FileUnlocker as administrator.");
            }

            Message.ShowInfo(sb.ToString());
        }

        /// <summary>
        /// Lists every file under a folder. Inaccessible subdirectories are skipped
        /// instead of aborting the whole run, which is what the old implementation did.
        /// </summary>
        private static List<string> EnumerateFiles(string directory, out bool truncated)
        {
            var files = new List<string>();
            truncated = false;

            try
            {
                foreach (string file in Directory.EnumerateFiles(directory, "*", FolderEnumeration))
                {
                    files.Add(file);
                }
            }
            catch (UnauthorizedAccessException)
            {
                // Nothing more can be reached in this tree. The files found so far are
                // still worth checking, but the caller must say the result is partial.
                truncated = true;
            }
            catch (DirectoryNotFoundException)
            {
                // A directory disappeared during the walk; the rest is still valid, but
                // the listing is genuinely incomplete.
                truncated = true;
            }
            catch (IOException)
            {
                truncated = true;
            }

            return files;
        }

        /// <summary>
        /// True when the path is a drive root or a share root, that is, when the path
        /// is its own root (<c>C:\</c>, <c>\</c>, <c>/</c>, <c>\\server\share</c>).
        /// </summary>
        private static bool IsRootPath(string fullPath)
        {
            try
            {
                string root = Path.GetPathRoot(fullPath);

                if (string.IsNullOrEmpty(root))
                {
                    return false;
                }

                string normalized = Path.TrimEndingDirectorySeparator(fullPath);
                string normalizedRoot = Path.TrimEndingDirectorySeparator(root);

                return string.Equals(normalized, normalizedRoot, StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception ex) when (IsInvalidPath(ex))
            {
                return false;
            }
        }

        /// <summary>
        /// True when the path can be read. A file that is locked by another process is
        /// still accessible: that is the normal case this tool is built for, so only an
        /// outright permission failure counts as inaccessible.
        /// </summary>
        private static bool IsAccessible(string path)
        {
            try
            {
                if (Directory.Exists(path))
                {
                    // Enumerating is lazy, so touch the first entry to prove the
                    // directory can actually be read.
                    using (IEnumerator<string> entries = Directory.EnumerateFileSystemEntries(path).GetEnumerator())
                    {
                        _ = entries.MoveNext();
                    }

                    return true;
                }

                if (File.Exists(path))
                {
                    using (File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    {
                        return true;
                    }
                }

                return false;
            }
            catch (UnauthorizedAccessException)
            {
                return false;
            }
            catch (IOException)
            {
                // A locked file cannot be opened; it still exists and is accessible.
                return true;
            }
            catch (Exception ex) when (IsInvalidPath(ex))
            {
                return false;
            }
        }

        private static bool IsInvalidPath(Exception ex)
        {
            return ex is ArgumentException ||
                   ex is NotSupportedException ||
                   ex is PathTooLongException ||
                   ex is IOException ||
                   ex is System.Security.SecurityException;
        }
    }
}
