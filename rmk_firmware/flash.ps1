<#
.SYNOPSIS
    Cannonball LL 自動ファームウェア書き込みスクリプト (Windows PowerShell)
.DESCRIPTION
    1. Cannonball LL の Raw HID (VID: 0x8884, PID: 0x0919) へ VIA Bootloader Jump コマンド (0x0B) を送信
    2. XIAO-SENSE / XIAO-BLE ドライブがマウントされるのを待機
    3. 指定された UF2 ファイルを自動コピーして書き込み完了
#>

param(
    [string]$Uf2 = "rmk-cannonball-ll.uf2",
    [int]$TimeoutSeconds = 15
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$uf2FullPath = Join-Path $scriptDir $Uf2

if (-not (Test-Path $uf2FullPath)) {
    # ワークスペース直下を探す
    $uf2FullPath = Resolve-Path $Uf2 -ErrorAction SilentlyContinue
    if (-not (Test-Path $uf2FullPath)) {
        Write-Error "UF2 ファイルが見つかりません: $Uf2"
        exit 1
    }
}

Write-Host "書き込み対象ファイル: $uf2FullPath" -ForegroundColor Cyan

# 1. 既にブートローダードライブが存在するか確認
function Get-BootloaderDrive {
    $drives = Get-Volume | Where-Object { $_.FileSystemLabel -in @('XIAO-SENSE', 'XIAO-BLE', 'NRF52BOOT') -and $_.DriveLetter }
    return $drives
}

$drive = Get-BootloaderDrive
if (-not $drive) {
    Write-Host "Cannonball LL をブートローダーモードへ切り替えます..." -ForegroundColor Yellow

    # Win32 HID API による Raw HID への VIA コマンド送信
    $hidSource = @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public class ViaBootloader {
    [DllImport("hid.dll", SetLastError = true)]
    private static extern void HidD_GetHidGuid(out Guid hidGuid);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, IntPtr enumerator, IntPtr hwndParent, uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(IntPtr deviceInfoSet, IntPtr deviceInfoData, ref Guid interfaceClassGuid, uint memberIndex, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr deviceInfoSet, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData, IntPtr deviceInterfaceDetailData, uint deviceInterfaceDetailDataSize, out uint requiredSize, IntPtr deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVICE_INTERFACE_DATA {
        public uint cbSize;
        public Guid interfaceClassGuid;
        public uint flags;
        public IntPtr reserved;
    }

    public static bool SendJumpCommand(ushort vid, ushort pid) {
        Guid hidGuid;
        HidD_GetHidGuid(out hidGuid);
        IntPtr hDevInfo = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero, 0x12); // DIGCF_PRESENT | DIGCF_DEVICEINTERFACE
        if (hDevInfo == IntPtr.Zero || hDevInfo.ToInt64() == -1) return false;

        string vidStr = string.Format("vid_{0:x4}&pid_{1:x4}", vid, pid);
        bool found = false;

        try {
            SP_DEVICE_INTERFACE_DATA ifData = new SP_DEVICE_INTERFACE_DATA();
            ifData.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));

            for (uint i = 0; SetupDiEnumDeviceInterfaces(hDevInfo, IntPtr.Zero, ref hidGuid, i, ref ifData); i++) {
                uint reqSize = 0;
                SetupDiGetDeviceInterfaceDetail(hDevInfo, ref ifData, IntPtr.Zero, 0, out reqSize, IntPtr.Zero);
                if (reqSize == 0) continue;

                IntPtr pDetail = Marshal.AllocHGlobal((int)reqSize);
                try {
                    Marshal.WriteInt32(pDetail, IntPtr.Size == 8 ? 8 : 4 + Marshal.SystemDefaultCharSize);
                    if (SetupDiGetDeviceInterfaceDetail(hDevInfo, ref ifData, pDetail, reqSize, out reqSize, IntPtr.Zero)) {
                        IntPtr pPath = new IntPtr(pDetail.ToInt64() + 4);
                        string path = Marshal.PtrToStringAuto(pPath);
                        if (path != null && path.ToLower().Contains(vidStr)) {
                            // Raw HID インターフェースを開く
                            SafeFileHandle handle = CreateFile(path, 0xC0000000, 0x03, IntPtr.Zero, 3, 0, IntPtr.Zero); // GENERIC_READ|WRITE, FILE_SHARE_READ|WRITE, OPEN_EXISTING
                            if (!handle.IsInvalid) {
                                using (FileStream stream = new FileStream(handle, FileAccess.ReadWrite, 33, false)) {
                                    // Report ID (0x00) + VIA Command (0x0B: BootloaderJump) + 31 bytes zero
                                    byte[] buf = new byte[33];
                                    buf[0] = 0x00;
                                    buf[1] = 0x0B;
                                    try {
                                        stream.Write(buf, 0, buf.Length);
                                        found = true;
                                        break;
                                    } catch {}
                                }
                            }
                        }
                    }
                } finally {
                    Marshal.FreeHGlobal(pDetail);
                }
            }
        } finally {
            SetupDiDestroyDeviceInfoList(hDevInfo);
        }
        return found;
    }
}
"@
    Add-Type -TypeDefinition $hidSource -ErrorAction SilentlyContinue

    $sent = [ViaBootloader]::SendJumpCommand(0x8884, 0x0919)
    if ($sent) {
        Write-Host "ブートローダー切り替えコマンド (VIA 0x0B) を送信しました。" -ForegroundColor Green
    } else {
        Write-Host "USB HID 経由でのデバイス検出またはコマンド送信に失敗しました。" -ForegroundColor Yellow
        Write-Host "※デバイスが既にブートローダー状態か、本体のリセットボタンを素早く2回押してください。" -ForegroundColor Yellow
    }

    # ドライブのマウントを待機
    Write-Host "ブートローダードライブ (XIAO-SENSE) のマウントを待機しています..." -NoNewline
    $waited = 0
    while ($waited -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 1
        $drive = Get-BootloaderDrive
        if ($drive) {
            Write-Host " 認識しました！" -ForegroundColor Green
            break
        }
        Write-Host "." -NoNewline
        $waited++
    }
    Write-Host ""
}

if (-not $drive) {
    Write-Error "タイムアウト: ブートローダードライブが見つかりませんでした。"
    exit 1
}

$destDrive = "$($drive.DriveLetter):\"
Write-Host "ターゲットドライブ: $destDrive ($($drive.FileSystemLabel))" -ForegroundColor Cyan
Write-Host "ファームウェアをコピー中..." -ForegroundColor Cyan

Copy-Item -Path $uf2FullPath -Destination $destDrive -Force

Write-Host "書き込み完了！Cannonball LL が再起動します。" -ForegroundColor Green
