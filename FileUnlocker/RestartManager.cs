using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace FileUnlocker
{
    public static class RestartManager
    {
		private const int RebootReasonNone = 0;
		private const int CCH_RM_MAX_APP_NAME = 255;
		private const int CCH_RM_MAX_SVC_NAME = 63;

		private enum RM_APP_TYPE
		{
			UnknownApp = 0,
			MainWindow = 1,
			OtherWindow = 2,
			Service = 3,
			Explorer = 4,
			Console = 5,
			Critical = 1000
		}

		[StructLayout(LayoutKind.Sequential)]
		private struct RM_UNIQUE_PROCESS
		{
			public int ProcessId;
			public FILETIME ProcessStartTime;
		}

		[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
		private struct RM_PROCESS_INFO
		{
			public RM_UNIQUE_PROCESS Process;

			[MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
			public string strAppName;

			[MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
			public string strServiceShortName;

			public RM_APP_TYPE ApplicationType;
			public uint AppStatus;
			public uint TSSessionId;

			[MarshalAs(UnmanagedType.Bool)]
			public bool bRestartable;
		}

		[DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
		private static extern int RmRegisterResources(uint pSessionHandle,
													  uint nFiles,
													  string[] rgsFilenames,
													  uint nApplications,
													  [In] RM_UNIQUE_PROCESS[] rgApplications,
													  uint nServices,
													  string[] rgsServiceNames);

		[DllImport("rstrtmgr.dll", CharSet = CharSet.Auto)]
		private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

		[DllImport("rstrtmgr.dll")]
		private static extern int RmEndSession(uint pSessionHandle);

		[DllImport("rstrtmgr.dll")]
		private static extern int RmGetList(uint dwSessionHandle,
											out uint pnProcInfoNeeded,
											ref uint pnProcInfo,
											[In, Out] RM_PROCESS_INFO[] rgAffectedApps,
											ref uint lpdwRebootReasons);

		public static List<Process> GetProcesses(string path)
		{
			string key = Guid.NewGuid().ToString();
			List<Process> processes = new List<Process>();

			int resource = RmStartSession(out uint handle, 0, key);
			if (resource != 0)
			{
				throw new Exception("Could not begin restart session.  Unable to determine file locker.");
			}

			try
			{
				const int ERROR_MORE_DATA = 234;
				uint pnProcessInfo = 0,
					 lpdwRebootReasons = RebootReasonNone;

				string[] resources = new string[] { path };

				resource = RmRegisterResources(handle, (uint)resources.Length, resources, 0, null, 0, null);

				if (resource != 0) throw new Exception("Could not register resource.");

				resource = RmGetList(handle, out uint pnProcInfoNeeded, ref pnProcessInfo, null, ref lpdwRebootReasons);

				if (resource == ERROR_MORE_DATA)
				{
					RM_PROCESS_INFO[] processInfo = new RM_PROCESS_INFO[pnProcInfoNeeded];
					pnProcessInfo = pnProcInfoNeeded;

					resource = RmGetList(handle, out pnProcInfoNeeded, ref pnProcessInfo, processInfo, ref lpdwRebootReasons);
					if (resource == 0)
					{
						processes = new List<Process>((int)pnProcessInfo);

						for (int i = 0; i < pnProcessInfo; i++)
						{
							try
							{
								processes.Add(Process.GetProcessById(processInfo[i].Process.ProcessId));
							}
							catch (ArgumentException) { }
						}
					}
					else throw new Exception("Could not list processes locking resource.");
				}
				else if (resource != 0) throw new Exception("Could not list processes locking resource. Failed to get size of result.");
			}
			finally
			{
				RmEndSession(handle);
			}

			return processes;
		}
	}
}
