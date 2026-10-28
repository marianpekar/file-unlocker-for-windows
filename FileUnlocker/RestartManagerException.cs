using System;
using System.ComponentModel;

namespace FileUnlocker
{
    /// <summary>
    /// Raised when a Restart Manager call fails. Carries the raw Win32 error code so
    /// the caller can show something meaningful instead of a bare message.
    /// </summary>
    public sealed class RestartManagerException : Exception
    {
        public RestartManagerException(string message, int errorCode)
            : base(message + " " + new Win32Exception(errorCode).Message + $" (error {errorCode}).")
        {
            ErrorCode = errorCode;
        }

        /// <summary>The Win32 error code returned by the Restart Manager.</summary>
        public int ErrorCode { get; }
    }
}
