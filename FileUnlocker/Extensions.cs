using System;
using System.IO;

namespace FileUnlocker
{
    public static class Extensions
    {
        public static bool IsDirectoryPath(this string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return false;
            }

            try
            {
                var attributes = File.GetAttributes(path);
                return attributes.HasFlag(FileAttributes.Directory);
            }
            catch
            {
                // Path may not exist or may be inaccessible
                return false;
            }
        }

        public static bool Exist(this string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return false;
            }

            return Directory.Exists(path) || File.Exists(path);
        }

        public static bool EqualsAny(this string str, StringComparison comparisonType, params string[] values)
        {
            if (str == null || values == null)
            {
                return false;
            }

            foreach (var value in values)
            {
                if (value != null && str.Equals(value, comparisonType))
                {
                    return true;
                }
            }

            return false;
        }
    }
}
