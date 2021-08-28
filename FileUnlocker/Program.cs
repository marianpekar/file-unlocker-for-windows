using System;

namespace FileUnlocker
{
    class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            string path = args[0];
            bool silent = args.Length > 1 && args[1].EqualsAny(StringComparison.OrdinalIgnoreCase, "-silent", "-s");

            FileUnlocker.Unlock(path, silent);
        }
    }
}
