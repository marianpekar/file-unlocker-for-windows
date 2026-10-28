namespace FileUnlocker
{
    /// <summary>
    /// Restart Manager application type (<c>RM_APP_TYPE</c>). The numeric values are
    /// the ones from rstrtmgr.h and must not be changed.
    /// </summary>
    public enum AppType
    {
        UnknownApp = 0,
        MainWindow = 1,
        OtherWindow = 2,
        Service = 3,
        Explorer = 4,
        Console = 5,
        Critical = 1000,
    }
}
