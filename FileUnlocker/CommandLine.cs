using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace FileUnlocker
{
    /// <summary>Parsed command line.</summary>
    public sealed class Options
    {
        /// <summary>Absolute path of the file or folder to unlock. Null for -help and -version.</summary>
        public string Path { get; set; }

        /// <summary>True when no dialog may be shown.</summary>
        public bool Silent { get; set; }

        /// <summary>True when the help text was requested.</summary>
        public bool ShowHelp { get; set; }

        /// <summary>True when the version was requested.</summary>
        public bool ShowVersion { get; set; }
    }

    /// <summary>Thrown for every invalid command line. Message is shown to the user as-is.</summary>
    public sealed class UsageException : Exception
    {
        public UsageException(string message)
            : base(message)
        {
        }
    }

    /// <summary>Command line parser and help text.</summary>
    public static class CommandLine
    {
        /// <summary>Version reported by -version and shown in the help header.</summary>
        public const string Version = "1.2.0";

        private static readonly string[] SilentNames = { "s", "silent" };
        private static readonly string[] HelpNames = { "h", "help", "?" };
        private static readonly string[] VersionNames = { "v", "version" };

        /// <summary>
        /// Parses the arguments.
        /// <para>
        /// Options may appear before, after or between positionals, and both
        /// <c>-name</c> and <c>/name</c> are accepted in any casing. A single
        /// <c>--</c> ends option parsing so a path that begins with <c>-</c> can be
        /// passed verbatim.
        /// </para>
        /// </summary>
        /// <exception cref="UsageException">The command line is invalid.</exception>
        public static Options Parse(string[] args)
        {
            var options = new Options();
            bool optionsEnded = false;
            string pathToken = null;

            if (args == null)
            {
                args = Array.Empty<string>();
            }

            for (int i = 0; i < args.Length; i++)
            {
                string token = args[i];

                if (optionsEnded)
                {
                    pathToken = AddPositional(pathToken, token);
                    continue;
                }

                if (token == "--")
                {
                    // Everything after -- is positional, verbatim.
                    optionsEnded = true;
                    continue;
                }

                if (IsOptionToken(token, out string name))
                {
                    if (name.EqualsAny(StringComparison.OrdinalIgnoreCase, SilentNames))
                    {
                        options.Silent = true;
                    }
                    else if (name.EqualsAny(StringComparison.OrdinalIgnoreCase, HelpNames))
                    {
                        options.ShowHelp = true;
                    }
                    else if (name.EqualsAny(StringComparison.OrdinalIgnoreCase, VersionNames))
                    {
                        options.ShowVersion = true;
                    }
                    else
                    {
                        throw new UsageException($"unknown option '{token}'.");
                    }

                    continue;
                }

                pathToken = AddPositional(pathToken, token);
            }

            if (options.ShowHelp || options.ShowVersion)
            {
                // These win over everything, including a missing or invalid path.
                return options;
            }

            if (pathToken == null)
            {
                throw new UsageException("no path was provided.");
            }

            string cleaned = pathToken.TrimQuotes();

            if (string.IsNullOrWhiteSpace(cleaned))
            {
                throw new UsageException("no path was provided.");
            }

            try
            {
                options.Path = Path.GetFullPath(cleaned);
            }
            catch (Exception ex) when (
                ex is ArgumentException ||
                ex is NotSupportedException ||
                ex is PathTooLongException ||
                ex is IOException)
            {
                throw new UsageException($"invalid path '{pathToken}': {ex.Message}");
            }

            return options;
        }

        private static string AddPositional(string current, string token)
        {
            if (current != null)
            {
                throw new UsageException($"unexpected argument '{token}'.");
            }

            return token;
        }

        /// <summary>
        /// Recognizes an option token and returns its bare name.
        /// <para>
        /// The rule, in full:
        /// </para>
        /// <list type="bullet">
        /// <item><description>
        /// Any token starting with <c>-</c> is an option. <c>--</c> alone ends option
        /// parsing and is handled by the caller. A lone <c>-</c> is an option whose
        /// name is empty, so it is reported as an unknown option rather than being
        /// mistaken for a path.
        /// </description></item>
        /// <item><description>
        /// A token starting with <c>/</c> is an option only when its bare name is one
        /// of the known names, matched exactly. This keeps <c>/silent</c> working while
        /// leaving Unix-style paths such as <c>/etc</c> or <c>/x</c> usable as paths.
        /// </description></item>
        /// </list>
        /// </summary>
        private static bool IsOptionToken(string token, out string name)
        {
            name = null;

            if (string.IsNullOrEmpty(token))
            {
                return false;
            }

            if (token[0] == '-')
            {
                name = token.Substring(1);
                return true;
            }

            if (token[0] == '/')
            {
                string candidate = token.Substring(1);

                if (IsKnownOptionName(candidate))
                {
                    name = candidate;
                    return true;
                }

                return false;
            }

            return false;
        }

        /// <summary>True when the bare name is one of the documented option names.</summary>
        private static bool IsKnownOptionName(string name)
        {
            return name.EqualsAny(StringComparison.OrdinalIgnoreCase, SilentNames) ||
                   name.EqualsAny(StringComparison.OrdinalIgnoreCase, HelpNames) ||
                   name.EqualsAny(StringComparison.OrdinalIgnoreCase, VersionNames);
        }

        /// <summary>The full help text: description, usage, options, exit codes, examples.</summary>
        public static string GetHelpText()
        {
            var sb = new StringBuilder();

            sb.AppendLine($"FileUnlocker {Version} - closes the processes that lock a file or a folder.");
            sb.AppendLine("Lets you move, rename or delete the item afterwards.");
            sb.AppendLine();
            sb.AppendLine("Usage:");
            sb.AppendLine("  FileUnlocker.exe <path> [options]");
            sb.AppendLine("  FileUnlocker.exe -help");
            sb.AppendLine("  FileUnlocker.exe -version");
            sb.AppendLine();
            sb.AppendLine("Options:");
            sb.AppendLine("  -s, -silent    Close the locking processes without asking. No dialog is shown.");
            sb.AppendLine("  -h, -help, -?  Show this help and exit.");
            sb.AppendLine("  -v, -version   Show the version and exit.");
            sb.AppendLine("  --             Treat the next argument as the path, even if it starts with '-'.");
            sb.AppendLine();
            sb.AppendLine("  Every option also accepts a '/' prefix (for example /silent or /SILENT),");
            sb.AppendLine("  matching is case-insensitive, and options may appear before or after the path.");
            sb.AppendLine("  A token starting with '-' is always an option; a token starting with '/'");
            sb.AppendLine("  is an option only when it is one of the names above, so '/etc' stays a path.");
            sb.AppendLine("  Drive roots such as 'C:\\', '/' or '\\\\server\\share' are refused: point at");
            sb.AppendLine("  a file or a folder inside them.");
            sb.AppendLine();
            sb.AppendLine("Exit codes:");
            sb.AppendLine("  0  the item is not locked, or all locking processes were closed");
            sb.AppendLine("  1  usage error");
            sb.AppendLine("  2  path not found or not accessible");
            sb.AppendLine("  3  nothing could be closed (for example, needs administrator)");
            sb.AppendLine("  4  partial: some processes could not be closed, or the item is still locked");
            sb.AppendLine("  5  cancelled (the user answered No; nothing changed)");
            sb.AppendLine("  6  unexpected error");
            sb.AppendLine();
            sb.AppendLine("Examples:");
            sb.AppendLine("  FileUnlocker.exe \"C:\\data\\report.docx\"");
            sb.AppendLine("  FileUnlocker.exe -silent \"C:\\data\"");
            sb.AppendLine("  FileUnlocker.exe -- \"-weird file name.txt\"");

            return sb.ToString();
        }
    }
}
