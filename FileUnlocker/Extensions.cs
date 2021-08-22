using System.IO;

namespace FileUnlocker
{
    public static class Extensions
    {
        public static bool IsDirectoryPath(this string path) => File.GetAttributes(path).HasFlag(FileAttributes.Directory);
        public static bool Exist(this string path) => (Directory.Exists(path) || File.Exists(path));
    }
}
