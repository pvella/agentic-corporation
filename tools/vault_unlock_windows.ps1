# Office Vault unlock for Windows: Windows Hello, falling back to the Windows
# account password when Hello is not set up. Run by tools/vault_auth.py; the
# Windows counterpart of tools/vault_unlock.swift (macOS LocalAuthentication).
#
#   AGENTIC_VAULT_REASON   prompt text (passed via env so it is never parsed)
#   AGENTIC_VAULT_METHOD   "password" skips Hello (for testing the fallback)
#
# Exit codes: 0 verified, 1 denied/cancelled, 2 no method available, 3 error.
# Detail goes to stderr. Plain ASCII on purpose: PowerShell 5.1 reads BOM-less
# scripts as ANSI. C# below sticks to C# 5 (what PS 5.1 Add-Type compiles).

$ErrorActionPreference = 'Stop'

$reason = $env:AGENTIC_VAULT_REASON
if (-not $reason) { $reason = 'Unlock the Agentic Corporation office vault' }
$caption = 'Agentic Corporation vault'

$src = @'
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace AgenticVault {

public static class Native {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}

// Windows.Security.Credentials.UI interop, without the WinRT projection.
[ComImport, Guid("39E050C3-4E74-441A-8DC0-B81104DF949C"),
 InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
interface IUserConsentVerifierInterop {
    void RequestVerificationForWindowAsync(IntPtr appWindow, IntPtr message,
                                           [In] ref Guid riid, out IntPtr asyncOperation);
}

[ComImport, Guid("00000036-0000-0000-C000-000000000046"),
 InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
interface IAsyncInfo {
    uint Id { get; }
    int Status { get; }      // 0 Started, 1 Completed, 2 Canceled, 3 Error
    int ErrorCode { get; }
    void Cancel();
    void Close();
}

// IAsyncOperation<UserConsentVerificationResult>. IID is the WinRT
// parameterized-interface hash of
// pinterface({9fc2b0bb-...};enum(Windows.Security.Credentials.UI.UserConsentVerificationResult;i4))
[ComImport, Guid("FD596FFD-2318-558F-9DBE-D21DF43764A5"),
 InterfaceType(ComInterfaceType.InterfaceIsIInspectable)]
interface IAsyncOperationVerificationResult {
    void put_Completed(IntPtr handler);
    IntPtr get_Completed();
    int GetResults();
}

public static class Hello {
    [DllImport("combase.dll", CharSet = CharSet.Unicode)]
    static extern int WindowsCreateString(string src, int length, out IntPtr hstring);
    [DllImport("combase.dll")]
    static extern int WindowsDeleteString(IntPtr hstring);
    [DllImport("combase.dll")]
    static extern int RoGetActivationFactory(IntPtr classId, [In] ref Guid iid, out IntPtr factory);

    static IntPtr HString(string s) {
        IntPtr h;
        Marshal.ThrowExceptionForHR(WindowsCreateString(s, s.Length, out h));
        return h;
    }

    // Returns UserConsentVerificationResult: 0 Verified, 1 DeviceNotPresent,
    // 2 NotConfiguredForUser, 3 DisabledByPolicy, 4 DeviceBusy,
    // 5 RetriesExhausted, 6 Canceled. Throws when the API is unavailable.
    public static int Verify(IntPtr hwnd, string message, int timeoutMs) {
        IntPtr cls = HString("Windows.Security.Credentials.UI.UserConsentVerifier");
        IntPtr msg = HString(message);
        IntPtr factoryPtr = IntPtr.Zero;
        try {
            Guid interopIid = typeof(IUserConsentVerifierInterop).GUID;
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(cls, ref interopIid, out factoryPtr));
            var interop = (IUserConsentVerifierInterop)Marshal.GetObjectForIUnknown(factoryPtr);
            Guid opIid = typeof(IAsyncOperationVerificationResult).GUID;
            IntPtr opPtr;
            interop.RequestVerificationForWindowAsync(hwnd, msg, ref opIid, out opPtr);
            object op = Marshal.GetObjectForIUnknown(opPtr);
            Marshal.Release(opPtr);
            var info = (IAsyncInfo)op;
            int waited = 0;
            while (info.Status == 0) {
                if (waited >= timeoutMs) { info.Cancel(); return 6; }
                Thread.Sleep(100);
                waited += 100;
            }
            if (info.Status == 2) return 6;
            if (info.Status == 3) Marshal.ThrowExceptionForHR(info.ErrorCode);
            return ((IAsyncOperationVerificationResult)op).GetResults();
        } finally {
            if (factoryPtr != IntPtr.Zero) Marshal.Release(factoryPtr);
            WindowsDeleteString(msg);
            WindowsDeleteString(cls);
        }
    }
}

public static class Password {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDUI_INFO {
        public int cbSize;
        public IntPtr hwndParent;
        public string pszMessageText;
        public string pszCaptionText;
        public IntPtr hbmBanner;
    }

    const int CREDUIWIN_ENUMERATE_CURRENT_USER = 0x200;
    const int CRED_PACK_PROTECTED_CREDENTIALS = 0x1;
    const int ERROR_CANCELLED = 1223;
    const int ERROR_LOGON_FAILURE = 1326;
    const int LOGON32_LOGON_INTERACTIVE = 2;
    const int LOGON32_PROVIDER_DEFAULT = 0;

    [DllImport("credui.dll", CharSet = CharSet.Unicode)]
    static extern int CredUIPromptForWindowsCredentials(ref CREDUI_INFO info, int authError,
        ref uint authPackage, IntPtr inBuffer, uint inBufferSize,
        out IntPtr outBuffer, out uint outBufferSize, ref bool save, int flags);

    [DllImport("credui.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredUnPackAuthenticationBuffer(int flags, IntPtr buffer, uint size,
        StringBuilder user, ref int userLen, StringBuilder domain, ref int domainLen,
        StringBuilder password, ref int passwordLen);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool LogonUser(string user, string domain, string password,
        int logonType, int provider, out IntPtr token);

    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("ole32.dll")] static extern void CoTaskMemFree(IntPtr p);

    static void Wipe(StringBuilder sb) {
        for (int i = 0; i < sb.Length; i++) sb[i] = '\0';
        sb.Length = 0;
    }

    // Returns 0 verified, 1 cancelled / wrong / different account. Message in detail.
    // One LogonUser call per entry, so a typo costs one lockout attempt, not several.
    public static int Verify(IntPtr hwnd, string caption, string message, int maxTries, out string detail) {
        string currentSid = WindowsIdentity.GetCurrent().User.Value;
        int authError = 0;
        for (int attempt = 0; attempt < maxTries; attempt++) {
            var info = new CREDUI_INFO();
            info.cbSize = Marshal.SizeOf(typeof(CREDUI_INFO));
            info.hwndParent = hwnd;
            info.pszCaptionText = caption;
            info.pszMessageText = message;
            uint package = 0;
            IntPtr outBuf;
            uint outSize;
            bool save = false;
            int rc = CredUIPromptForWindowsCredentials(ref info, authError, ref package,
                IntPtr.Zero, 0, out outBuf, out outSize, ref save, CREDUIWIN_ENUMERATE_CURRENT_USER);
            if (rc == ERROR_CANCELLED) { detail = "cancelled"; return 1; }
            if (rc != 0) { detail = "credential prompt failed (error " + rc + ")"; return 1; }

            var user = new StringBuilder(1024); int userLen = user.Capacity;
            var domain = new StringBuilder(1024); int domainLen = domain.Capacity;
            var pass = new StringBuilder(1024); int passLen = pass.Capacity;
            bool unpacked;
            try {
                unpacked = CredUnPackAuthenticationBuffer(CRED_PACK_PROTECTED_CREDENTIALS, outBuf, outSize,
                    user, ref userLen, domain, ref domainLen, pass, ref passLen);
            } finally {
                Marshal.Copy(new byte[outSize], 0, outBuf, (int)outSize);
                CoTaskMemFree(outBuf);
            }
            if (!unpacked) {
                Wipe(pass);
                detail = "enter your Windows account password (PIN and smart card are not supported here)";
                return 1;
            }

            // CredUI returns "DOMAIN\user" (local: "PC-NAME\user", Microsoft account:
            // "MicrosoftAccount\name@example.com"); a bare UPN has no backslash.
            string full = user.ToString();
            string u = full, d = null;
            int slash = full.IndexOf('\\');
            if (slash > 0) { d = full.Substring(0, slash); u = full.Substring(slash + 1); }
            if (domain.Length > 0 && d == null) d = domain.ToString();

            IntPtr token;
            bool ok = LogonUser(u, d, pass.ToString(), LOGON32_LOGON_INTERACTIVE,
                                LOGON32_PROVIDER_DEFAULT, out token);
            int err = Marshal.GetLastWin32Error();
            Wipe(pass);
            if (ok) {
                try {
                    using (var id = new WindowsIdentity(token)) {
                        if (id.User != null && id.User.Value == currentSid) { detail = "ok"; return 0; }
                    }
                } finally { CloseHandle(token); }
                detail = "that is a different Windows account; sign in as the current user";
                return 1;
            }
            if (err != ERROR_LOGON_FAILURE) {
                detail = "Windows rejected the sign-in (error " + err + ")";
                return 1;
            }
            authError = ERROR_LOGON_FAILURE;  // CredUI shows "incorrect password" on re-prompt
        }
        detail = "incorrect password";
        return 1;
    }
}

}
'@

try {
    Add-Type -TypeDefinition $src -Language CSharp
} catch {
    [Console]::Error.WriteLine("vault unlock helper failed to compile: $($_.Exception.Message)")
    exit 3
}

$hwnd = [AgenticVault.Native]::GetForegroundWindow()
$helloNote = ''

if ($env:AGENTIC_VAULT_METHOD -ne 'password') {
    $result = -1
    try {
        $result = [AgenticVault.Hello]::Verify($hwnd, $reason, 120000)
    } catch {
        $helloNote = "Windows Hello unavailable ($($_.Exception.Message))"
    }
    switch ($result) {
        0 { [Console]::Out.WriteLine('ok (Windows Hello)'); exit 0 }
        1 { $helloNote = 'no Windows Hello device' }
        2 { $helloNote = 'Windows Hello not set up for this user' }
        3 { $helloNote = 'Windows Hello disabled by policy' }
        4 { [Console]::Error.WriteLine('Windows Hello is busy; try again'); exit 1 }
        5 { [Console]::Error.WriteLine('too many failed Windows Hello attempts'); exit 1 }
        6 { [Console]::Error.WriteLine('cancelled'); exit 1 }
    }
}

# Hello not available (never on cancel/failure): ask for the account password.
try {
    $detail = ''
    $rc = [AgenticVault.Password]::Verify($hwnd, $caption, $reason, 3, [ref]$detail)
} catch {
    [Console]::Error.WriteLine("password check failed: $($_.Exception.Message)")
    exit 2
}
if ($rc -eq 0) {
    $how = 'Windows password'
    if ($helloNote) { $how = "$how; $helloNote" }
    [Console]::Out.WriteLine("ok ($how)")
    exit 0
}
[Console]::Error.WriteLine($detail)
exit 1
