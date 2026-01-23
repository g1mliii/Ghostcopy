$ErrorActionPreference = "Stop"

$shortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\GhostCopy.lnk"
$appId = "com.ghostcopy.app"

Write-Host "--- DIAGNOSTIC START ---"

# 1. Verify Shortcut Existence
if (-not (Test-Path $shortcutPath)) {
    Write-Error "CRITICAL: Shortcut not found at $shortcutPath"
    exit 1
}
Write-Host "✅ Shortcut found."

# 2. Inspect Shortcut AUMI
$code = @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace DebugShell {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class ShellLink {}

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] string pszFile, int cch, IntPtr pfd, int fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] string pszName, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] string pszDir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] string pszArgs, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int cch, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, int dwReserved);
        void Resolve(IntPtr hwnd, int fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99")]
    interface IPropertyStore {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PropertyKey pkey);
        void GetValue(ref PropertyKey key, out PropVariant pv);
        void SetValue(ref PropertyKey key, ref PropVariant pv);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr unionmember;
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
    public interface IPersistFile {
        void GetClassID(out Guid pClassID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    public static class KeyReader {
        public static string GetAppId(string shortcutPath) {
            IShellLinkW newShortcut = (IShellLinkW)new ShellLink();
            ((IPersistFile)newShortcut).Load(shortcutPath, 0);
            
            IPropertyStore propertyStore = (IPropertyStore)newShortcut;
            PropertyKey appIdKey = new PropertyKey { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 }; // System.AppUserModel.ID
            
            PropVariant pv;
            propertyStore.GetValue(ref appIdKey, out pv);
            
            if (pv.vt == 31) { // VT_LPWSTR
                return Marshal.PtrToStringUni(pv.unionmember);
            }
            return null;
        }
    }
}
"@

Add-Type -TypeDefinition $code
$readAppId = [DebugShell.KeyReader]::GetAppId($shortcutPath)

Write-Host "Read AppID from Shortcut: '$readAppId'"

if ($readAppId -eq $appId) {
    Write-Host "✅ AppID MATCHES target ($appId)"
}
else {
    Write-Host "❌ AppID MISMATCH. Expected '$appId', found '$readAppId'"
    exit 1
}

# 3. Attempt Native Toast
Write-Host "Attempting to send native TEST toast using AppID '$appId'..."

$xml = @"
<toast>
    <visual>
        <binding template=""ToastGeneric"">
            <text>GhostCopy Diagnostic</text>
            <text>If you see this, the Shortcut/AUMI registration is WORKING.</text>
        </binding>
    </visual>
</toast>
"@

$xmlDoc = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]::new()
$xmlDoc.LoadXml($xml)

$notifier = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]::CreateToastNotifier($appId)
$toast = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]::new($xmlDoc)

try {
    $notifier.Show($toast)
    Write-Host "✅ Native Toast command sent."
    Write-Host "CHECK YOUR NOTIFICATION CENTER NOW."
}
catch {
    Write-Error "❌ Failed to send toast: $_"
}

Write-Host "--- DIAGNOSTIC END ---"
