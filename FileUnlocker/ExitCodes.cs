namespace FileUnlocker
{
    /// <summary>
    /// Process exit codes. These values are part of the public contract and are
    /// documented in the help text.
    /// </summary>
    public static class ExitCodes
    {
        /// <summary>The item is not locked, or every locking process was closed.</summary>
        public const int Success = 0;

        /// <summary>The command line was invalid (missing path, unknown option, too many arguments).</summary>
        public const int Usage = 1;

        /// <summary>The path does not exist or is not accessible.</summary>
        public const int NotFound = 2;

        /// <summary>Nothing could be closed, for example because administrator rights are required.</summary>
        public const int NothingClosed = 3;

        /// <summary>Partial result: some processes could not be closed, or the item is still locked.</summary>
        public const int Partial = 4;

        /// <summary>The user answered No; nothing was changed.</summary>
        public const int Cancelled = 5;

        /// <summary>An unexpected error, from the Restart Manager or from this program.</summary>
        public const int UnexpectedError = 6;
    }
}
