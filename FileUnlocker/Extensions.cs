using System;
using System.IO;

namespace FileUnlocker
{
    /// <summary>Path helpers shared by the command line parser and the unlock logic.</summary>
    public static class Extensions
    {
        /// <summary>True when the path is an existing file or directory.</summary>
        public static bool Exist(this string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return false;
            }

            return File.Exists(path) || Directory.Exists(path);
        }

        /// <summary>
        /// True when the path points at a directory. Returns false when the path does
        /// not exist or cannot be inspected, rather than throwing.
        /// </summary>
        public static bool IsDirectoryPath(this string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return false;
            }

            try
            {
                return File.GetAttributes(path).HasFlag(FileAttributes.Directory);
            }
            catch
            {
                // Path may not exist or may be inaccessible.
                return false;
            }
        }

        /// <summary>
        /// Removes one surrounding pair of double quotes, if present. Explorer always
        /// quotes the path, and a hand-typed command line often quotes it as well.
        /// </summary>
        public static string TrimQuotes(this string path)
        {
            if (string.IsNullOrEmpty(path))
            {
                return path;
            }

            if (path.Length >= 2 && path[0] == '"' && path[path.Length - 1] == '"')
            {
                return path.Substring(1, path.Length - 2);
            }

            return path;
        }

        /// <summary>
        /// Name used in dialogs. Uses the last path segment, and falls back to the
        /// path root for paths such as <c>C:\</c> so the name is never empty.
        /// </summary>
        public static string GetDisplayName(this string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return path;
            }

            try
            {
                string name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
                if (!string.IsNullOrEmpty(name))
                {
                    return name;
                }

                string root = Path.GetPathRoot(Path.GetFullPath(path));
                return string.IsNullOrEmpty(root) ? path : root;
            }
            catch
            {
                return path;
            }
        }

        /// <summary>Case-insensitive comparison against any of the given values.</summary>
        public static bool EqualsAny(this string str, StringComparison comparisonType, params string[] values)
        {
            if (str == null || values == null)
            {
                return false;
            }

            foreach (string value in values)
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
