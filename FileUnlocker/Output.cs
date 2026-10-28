using System;

namespace FileUnlocker
{
    /// <summary>
    /// Console writer used by every code path.
    /// <para>
    /// This program is a GUI-subsystem executable, so it has no console of its own.
    /// When it is launched from an existing console the inherited handles still work
    /// and writes appear normally. Attaching to or allocating a console makes all
    /// output disappear on this setup, so that is never done here.
    /// </para>
    /// <para>
    /// Every write is wrapped so that a closed, broken or redirected-to-nowhere
    /// handle can never throw and can never turn a normal run into a crash.
    /// </para>
    /// </summary>
    public static class Output
    {
        private const string Prefix = "FileUnlocker: ";

        /// <summary>Writes an informational line to standard output.</summary>
        public static void Info(string message)
        {
            Write(Console.Out, Prefix + message);
        }

        /// <summary>Writes a line that is already complete to standard output.</summary>
        public static void Line(string message)
        {
            Write(Console.Out, message);
        }

        /// <summary>Writes an error line to standard error.</summary>
        public static void Error(string message)
        {
            Write(Console.Error, Prefix + "error: " + message);
        }

        /// <summary>Writes an error line and the usage hint to standard error.</summary>
        public static void UsageError(string message)
        {
            Write(Console.Error, Prefix + "error: " + message);
            Write(Console.Error, Prefix + "run 'FileUnlocker.exe -help' for usage.");
        }

        private static void Write(System.IO.TextWriter writer, string line)
        {
            try
            {
                writer.WriteLine(line);
                writer.Flush();
            }
            catch
            {
                // The output handle may be closed, broken or redirected to nowhere.
                // Losing an informational line is acceptable; throwing is not.
            }
        }
    }
}
