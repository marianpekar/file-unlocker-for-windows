using System;
using System.Runtime.InteropServices;

namespace FileUnlocker
{
    /// <summary>
    /// Message box dialogs. Every dialog is forced to the foreground and made
    /// topmost, because a dialog opened from the Explorer context menu otherwise
    /// tends to appear behind the Explorer window.
    /// </summary>
    public static class Message
    {
        /// <summary>Dialog title used everywhere.</summary>
        public const string Title = "Unlock";

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int MessageBox(IntPtr hWnd, string text, string caption, uint type);

        private const uint MB_OK = 0x00000000;
        private const uint MB_YESNO = 0x00000004;
        private const uint MB_ICONERROR = 0x00000010;
        private const uint MB_ICONQUESTION = 0x00000020;
        private const uint MB_ICONWARNING = 0x00000030;
        private const uint MB_ICONINFORMATION = 0x00000040;
        private const uint MB_DEFBUTTON2 = 0x00000100;
        private const uint MB_TOPMOST = 0x00040000;
        private const uint MB_SETFOREGROUND = 0x00010000;

        private const int IDYES = 6;
        private const int IDNO = 7;

        /// <summary>Shows an informational dialog.</summary>
        public static void ShowInfo(string message)
        {
            Show(message, MB_OK | MB_ICONINFORMATION);
        }

        /// <summary>Shows an error dialog.</summary>
        public static void ShowError(string message)
        {
            Show(message, MB_OK | MB_ICONERROR);
        }

        /// <summary>
        /// Asks a yes or no question. The default button is No, so pressing Enter
        /// by accident never closes anything.
        /// </summary>
        /// <returns>True when the user confirmed.</returns>
        public static bool Confirm(string message)
        {
            int result = Show(message, MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2 | MB_TOPMOST | MB_SETFOREGROUND);
            return result == IDYES;
        }

        private static int Show(string message, uint type)
        {
            return MessageBox(IntPtr.Zero, message ?? string.Empty, Title, type);
        }
    }
}
