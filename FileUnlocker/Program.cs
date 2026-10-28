using System;

namespace FileUnlocker
{
    /// <summary>
    /// Entry point. Everything is wrapped so that no failure can ever escape as an
    /// unhandled exception: an exception in a GUI-subsystem executable is invisible
    /// when it is launched from Explorer.
    /// </summary>
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            Options options = null;
            bool silent = false;

            try
            {
                options = CommandLine.Parse(args);
                silent = options.Silent;

                if (options.ShowHelp)
                {
                    Output.Line(CommandLine.GetHelpText());
                    return ExitCodes.Success;
                }

                if (options.ShowVersion)
                {
                    // Output.Info already prefixes with "FileUnlocker: ", so the name
                    // must not be repeated here.
                    Output.Info(CommandLine.Version);
                    return ExitCodes.Success;
                }

                return FileUnlocker.Run(options);
            }
            catch (UsageException ex)
            {
                Output.UsageError(ex.Message);
                return ExitCodes.Usage;
            }
            catch (RestartManagerException ex)
            {
                Output.Error(ex.Message);

                if (!silent)
                {
                    Message.ShowError(ex.Message);
                }

                return ExitCodes.UnexpectedError;
            }
            catch (Exception ex)
            {
                Output.Error(ex.Message);

                if (!silent)
                {
                    Message.ShowError(ex.Message);
                }

                return ExitCodes.UnexpectedError;
            }
        }
    }
}
