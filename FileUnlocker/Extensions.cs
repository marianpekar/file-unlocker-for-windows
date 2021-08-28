using System;
using System.IO;

namespace FileUnlocker
{
    public static class Extensions
    {
        public static bool IsDirectoryPath(this string path) => File.GetAttributes(path).HasFlag(FileAttributes.Directory);
        public static bool Exist(this string path) => (Directory.Exists(path) || File.Exists(path));

        public static bool EqualsAny(this string str, StringComparison comparisonType, params string[] values) 
        {
            foreach (var value in values)
            {
                if (str.Equals(value, comparisonType))
                    return true;
            }

            return false;
        }
    }
}
