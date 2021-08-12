using System;
using System.Runtime.InteropServices;

namespace FileUnlocker
{
    public static class Message
    {

        [DllImport("User32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBox(IntPtr h, string m, string c, uint type);

        public static void Show(string message, string title) 
        {
            MessageBox((IntPtr)0, message, title, (uint)TYPE.MB_OK);
        }

        private enum TYPE 
        {
            MB_OK = 0,
            MB_YESNO = 4,
        }

        private enum RESULT {
            MB_YES = 6,
            MB_NO = 7
        }

        public static void ShowYesNoDialog<T>(string message, string title, Action<T> OnYes, Action<T> OnNo, T obj)
        {
            RESULT result = (RESULT)MessageBox((IntPtr)0, message, title, (uint)TYPE.MB_YESNO);

            switch (result)
            {
                case RESULT.MB_YES:
                    OnYes?.Invoke(obj);
                    break;
                case RESULT.MB_NO:
                    OnNo?.Invoke(obj);
                    break;
                default:
                    break;
            }
        }
    }
}
