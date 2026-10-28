using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace FileUnlocker
{
    /// <summary>
    /// Thin wrapper over the Windows Restart Manager API.
    /// <para>
    /// One session is opened per run. Files are registered in batches, and the whole
    /// list is queried once, which is what makes a large folder fast: the old design
    /// opened a session per file and took about 12 ms per file.
    /// </para>
    /// <para>
    /// The wrapper returns plain model objects and never hands out process handles.
    /// Failures are reported as <see cref="RestartManagerException"/> with the Win32
    /// error code.
    /// </para>
    /// </summary>
    public sealed class RestartManagerSession : IDisposable
    {
        private const int RebootReasonNone = 0;
        private const int CCH_RM_MAX_APP_NAME = 255;
        private const int CCH_RM_MAX_SVC_NAME = 63;

        /// <summary>Number of files registered per RmRegisterResources call.</summary>
        private const int RegisterBatchSize = 512;

        /// <summary>How many times RmGetList is retried while it reports ERROR_MORE_DATA.</summary>
        private const int GetListAttempts = 3;

        private const int ERROR_SUCCESS = 0;
        private const int ERROR_MORE_DATA = 234;

        /// <summary>
        /// Session key buffer. CCH_RM_SESSION_KEY is 32, so 33 characters are required.
        /// A shorter buffer caused a real access violation, so this size is fixed.
        /// </summary>
        private const int CCH_RM_SESSION_KEY = 32;

        private uint _handle;
        private bool _started;

        [StructLayout(LayoutKind.Sequential)]
        private struct RM_UNIQUE_PROCESS
        {
            public int ProcessId;
            public FILETIME ProcessStartTime;
        }

        /// <summary>
        /// Marshals to exactly 668 bytes on x64. The layout is correct and must not
        /// be reordered or padded.
        /// </summary>
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct RM_PROCESS_INFO
        {
            public RM_UNIQUE_PROCESS Process;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
            public string strAppName;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
            public string strServiceShortName;

            public AppType ApplicationType;
            public uint AppStatus;
            public uint TSSessionId;

            [MarshalAs(UnmanagedType.Bool)]
            public bool bRestartable;
        }

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmRegisterResources(
            uint pSessionHandle,
            uint nFiles,
            string[] rgsFilenames,
            uint nApplications,
            [In] RM_UNIQUE_PROCESS[] rgApplications,
            uint nServices,
            string[] rgsServiceNames);

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, char[] strSessionKey);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmEndSession(uint pSessionHandle);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmGetList(
            uint dwSessionHandle,
            out uint pnProcInfoNeeded,
            ref uint pnProcInfo,
            [In, Out] RM_PROCESS_INFO[] rgAffectedApps,
            ref uint lpdwRebootReasons);

        /// <summary>Opens a Restart Manager session.</summary>
        /// <exception cref="RestartManagerException">The session could not be started.</exception>
        public RestartManagerSession()
        {
            var key = new char[CCH_RM_SESSION_KEY + 1];
            int result = RmStartSession(out _handle, 0, key);

            if (result != ERROR_SUCCESS)
            {
                throw new RestartManagerException("Could not start a Restart Manager session.", result);
            }

            _started = true;
        }

        /// <summary>
        /// Registers every file and then asks the Restart Manager which processes are
        /// using them.
        /// </summary>
        /// <param name="files">Absolute file paths. Directory paths must be expanded first.</param>
        /// <param name="skippedCount">Number of files that could not be registered.</param>
        /// <exception cref="RestartManagerException">Registration or listing failed.</exception>
        public List<LockingProcess> GetLockingProcesses(IReadOnlyList<string> files, out int skippedCount)
        {
            if (!_started)
            {
                throw new InvalidOperationException("The session has not been started.");
            }

            skippedCount = RegisterFiles(files);
            return QueryProcesses();
        }

        /// <summary>
        /// Registers files in batches. A failing batch is retried file by file so one
        /// bad path cannot discard the rest of the folder. Returns the number of files
        /// that could not be registered at all.
        /// </summary>
        private int RegisterFiles(IReadOnlyList<string> files)
        {
            if (files == null || files.Count == 0)
            {
                return 0;
            }

            int skipped = 0;
            var batch = new List<string>(RegisterBatchSize);

            for (int i = 0; i < files.Count; i++)
            {
                batch.Add(files[i]);

                if (batch.Count == RegisterBatchSize || i == files.Count - 1)
                {
                    skipped += RegisterBatch(batch);
                    batch.Clear();
                }
            }

            return skipped;
        }

        private int RegisterBatch(List<string> batch)
        {
            string[] names = batch.ToArray();
            int result = RmRegisterResources(_handle, (uint)names.Length, names, 0, null, 0, null);

            if (result == ERROR_SUCCESS)
            {
                return 0;
            }

            // The batch failed as a whole (a path that no longer exists is the usual
            // reason), so fall back to one call per file and drop only the bad ones.
            int skipped = 0;

            foreach (string name in names)
            {
                var single = new[] { name };
                if (RmRegisterResources(_handle, 1, single, 0, null, 0, null) != ERROR_SUCCESS)
                {
                    skipped++;
                }
            }

            return skipped;
        }

        private List<LockingProcess> QueryProcesses()
        {
            uint needed = 0;
            uint count = 0;
            uint rebootReasons = RebootReasonNone;

            int result = RmGetList(_handle, out needed, ref count, null, ref rebootReasons);

            if (result == ERROR_SUCCESS)
            {
                // Nothing is using the registered files.
                return new List<LockingProcess>();
            }

            if (result != ERROR_MORE_DATA)
            {
                throw new RestartManagerException("Could not list the processes locking the item.", result);
            }

            for (int attempt = 0; attempt < GetListAttempts; attempt++)
            {
                var buffer = new RM_PROCESS_INFO[needed];
                count = needed;
                rebootReasons = RebootReasonNone;

                result = RmGetList(_handle, out needed, ref count, buffer, ref rebootReasons);

                if (result == ERROR_SUCCESS)
                {
                    return Convert(buffer, count);
                }

                if (result != ERROR_MORE_DATA)
                {
                    throw new RestartManagerException("Could not list the processes locking the item.", result);
                }

                // The list grew between the two calls; ask again with the bigger size.
                count = 0;
            }

            throw new RestartManagerException(
                "Could not list the processes locking the item: the list kept changing.",
                ERROR_MORE_DATA);
        }

        private static List<LockingProcess> Convert(RM_PROCESS_INFO[] buffer, uint count)
        {
            var processes = new List<LockingProcess>((int)count);

            for (int i = 0; i < count && i < buffer.Length; i++)
            {
                processes.Add(new LockingProcess
                {
                    ProcessId = buffer[i].Process.ProcessId,
                    StartTime = LockingProcess.StartTimeFromFileTime(buffer[i].Process.ProcessStartTime),
                    ProcessName = TryGetProcessName(buffer[i].Process.ProcessId),
                    AppName = buffer[i].strAppName,
                    ServiceShortName = buffer[i].strServiceShortName,
                    AppType = buffer[i].ApplicationType,
                    Restartable = buffer[i].bRestartable,
                });
            }

            return processes;
        }

        private static string TryGetProcessName(int processId)
        {
            try
            {
                using (System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById(processId))
                {
                    return process.ProcessName;
                }
            }
            catch (ArgumentException)
            {
                // The process exited between the query and this call.
                return null;
            }
            catch (InvalidOperationException)
            {
                return null;
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // The process exists but is not inspectable.
                return null;
            }
        }

        /// <summary>Closes the session. Safe to call more than once.</summary>
        public void Dispose()
        {
            if (_started)
            {
                _started = false;
                RmEndSession(_handle);
            }
        }
    }
}
