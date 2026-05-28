Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$typeDefinition = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class DdcCi {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int left, top, right, bottom; }

    public delegate bool MonitorEnumDelegate(IntPtr hMonitor, IntPtr hdcMonitor, ref Rect lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll", SetLastError = false)]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumDelegate lpfnEnum, IntPtr dwData);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint pdwNumberOfPhysicalMonitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint dwPhysicalMonitorArraySize, [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool DestroyPhysicalMonitors(uint dwPhysicalMonitorArraySize, PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool SetVCPFeature(IntPtr hMonitor, byte bVCPCode, uint dwNewValue);

    public static List<IntPtr> Monitors = new List<IntPtr>();

    public static bool CaptureMonitor(IntPtr hMonitor, IntPtr hdcMonitor, ref Rect lprcMonitor, IntPtr dwData)
    {
        Monitors.Add(hMonitor);
        return true;
    }

    public static IntPtr[] EnumerateMonitors()
    {
        Monitors.Clear();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, CaptureMonitor, IntPtr.Zero);
        return Monitors.ToArray();
    }
}
'@
Add-Type -TypeDefinition $typeDefinition

function Get-WmiMonitorInfo {
    $items = @()
    try {
        $wmiEntries = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop
        foreach ($entry in $wmiEntries) {
            $manufacturer = ($entry.ManufacturerName | ForEach-Object {[char]$_} | Where-Object { $_ -ne "`0" }) -join ""
            $product = ($entry.ProductCodeID | ForEach-Object {[char]$_} | Where-Object { $_ -ne "`0" }) -join ""
            $serial = ($entry.SerialNumberID | ForEach-Object {[char]$_} | Where-Object { $_ -ne "`0" }) -join ""
            $userName = ($entry.UserFriendlyName | ForEach-Object {[char]$_} | Where-Object { $_ -ne "`0" }) -join ""
            $items += [pscustomobject]@{
                InstanceName     = $entry.InstanceName
                Manufacturer     = $manufacturer.Trim()
                ProductCodeID    = $product.Trim()
                SerialNumber     = $serial.Trim()
                UserFriendlyName = $userName.Trim()
            }
        }
    } catch {
        # ignore WMI lookup failures
    }
    return $items
}

function Get-PhysicalMonitors {
    $handleList = [DdcCi]::EnumerateMonitors()
    $monitors = @()
    $wmiInfo = Get-WmiMonitorInfo

    foreach ($hMonitor in $handleList) {
        $count = 0
        if (-not [DdcCi]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMonitor, [ref]$count)) {
            continue
        }

        if ($count -le 0) {
            continue
        }

        $array = New-Object DdcCi+PHYSICAL_MONITOR[] $count
        if (-not [DdcCi]::GetPhysicalMonitorsFromHMONITOR($hMonitor, [uint32]$count, $array)) {
            continue
        }

        for ($i = 0; $i -lt $count; $i++) {
            $description = $array[$i].szPhysicalMonitorDescription.Trim()
            if ([string]::IsNullOrWhiteSpace($description)) {
                $description = "Monitor $($monitors.Count + 1)"
            }

            $wmi = if ($monitors.Count -lt $wmiInfo.Count) { $wmiInfo[$monitors.Count] } else { $null }
            if ($wmi -and $wmi.UserFriendlyName) {
                $description = "$($wmi.UserFriendlyName) ($description)"
            } elseif ($wmi -and $wmi.Manufacturer) {
                $description = "$($wmi.Manufacturer) $($wmi.ProductCodeID) ($description)"
            }

            $monitors += [pscustomobject]@{
                MonitorHandle    = $hMonitor
                PhysicalHandle   = $array[$i].hPhysicalMonitor
                Description      = $description
                WmiInfo          = $wmi
                PhysicalArray    = $array
            }
        }
    }

    return $monitors
}

function Close-PhysicalMonitors {
    param(
        [object[]]$Monitors
    )

    $arrays = $Monitors | Select-Object -ExpandProperty PhysicalArray -Unique
    foreach ($arr in $arrays) {
        if ($arr -is [System.Array]) {
            [DdcCi]::DestroyPhysicalMonitors([uint32]$arr.Length, $arr) | Out-Null
        }
    }
}

function Set-MonitorInput {
    param(
        $Monitor,
        [uint32]$InputCode
    )

    $success = [DdcCi]::SetVCPFeature($Monitor.PhysicalHandle, 0x60, $InputCode)
    if (-not $success) {
        $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Failed to switch input (DDC/CI set failed, error 0x$([Convert]::ToString($errorCode,16))). Verify that DDC/CI is enabled in the monitor OSD."
    }
    
    # Add delay to allow monitor to process the input switch command
    Start-Sleep -Milliseconds 300
}

function Build-Form {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Monitor Input Switcher'
    $form.Width = 520
    $form.Height = 420
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Select a monitor, then click a button to switch input.'
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $form.Controls.Add($label)

    $monitorList = New-Object System.Windows.Forms.ListBox
    $monitorList.Name = 'MonitorListBox'
    $monitorList.Location = New-Object System.Drawing.Point(12, 40)
    $monitorList.Size = New-Object System.Drawing.Size(480, 120)
    $monitorList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.Controls.Add($monitorList)

    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Location = New-Object System.Drawing.Point(12, 170)
    $buttonPanel.Size = New-Object System.Drawing.Size(480, 55)
    $form.Controls.Add($buttonPanel)

    $buttons = @(
        @{ Text = 'HDMI1'; Code = 0x11 },
        @{ Text = 'HDMI2'; Code = 0x12 },
        @{ Text = 'DP1';   Code = 0x0F },
        @{ Text = 'DP2';   Code = 0x10 }
    )

    for ($i = 0; $i -lt $buttons.Count; $i++) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $buttons[$i].Text
        $btn.Tag = $buttons[$i].Code
        $btn.Size = New-Object System.Drawing.Size(110, 35)
        $xPos = [int](5 + ($i * 120))
        $btn.Location = New-Object System.Drawing.Point($xPos, 10)
        $btn.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $buttonPanel.Controls.Add($btn)
        # Capture the button properly in closure to avoid variable reference issues
        $btn.Add_Click({
            param($sender)
            Switch-Input $form $sender
        })
    }

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = 'Refresh Monitors'
    $refreshButton.Size = New-Object System.Drawing.Size(140, 30)
    $refreshButton.Location = New-Object System.Drawing.Point(12, 235)
    $refreshButton.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.Controls.Add($refreshButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Size = New-Object System.Drawing.Size(140, 30)
    $closeButton.Location = New-Object System.Drawing.Point(352, 235)
    $closeButton.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $closeButton.Add_Click({ $form.Close() })
    $form.Controls.Add($closeButton)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.ReadOnly = $true
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $logBox.Location = New-Object System.Drawing.Point(12, 276)
    $logBox.Size = New-Object System.Drawing.Size(480, 95)
    $form.Controls.Add($logBox)

    $form.Tag = [pscustomobject]@{
        ListBox  = $monitorList
        LogBox   = $logBox
        Monitors = @()
    }

    $refreshButton.Add_Click({ Load-Monitors $form })

    return $form
}

function Log-Message {
    param(
        [System.Windows.Forms.TextBox]$LogBox,
        [string]$Message
    )
    $time = Get-Date -Format 'HH:mm:ss'
    $LogBox.AppendText("[$time] $Message`r`n")
}

function Load-Monitors {
    param(
        [System.Windows.Forms.Form]$Form
    )

    $monitorList = $Form.Tag.ListBox
    $monitorList.Items.Clear()
    $Form.Tag.Monitors = @()

    $monitors = Get-PhysicalMonitors
    if (-not $monitors -or $monitors.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No DDC/CI-capable monitors were found. Make sure DDC/CI is enabled in the monitor OSD.', 'Monitor Input Switcher', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    foreach ($monitor in $monitors) {
        $monitorList.Items.Add($monitor.Description)
        $Form.Tag.Monitors += $monitor
    }

    if ($monitorList.Items.Count -gt 0) {
        $monitorList.SelectedIndex = 0
    }

    Log-Message -LogBox $Form.Tag.LogBox -Message "Loaded $($monitors.Count) monitor(s)."
}

function Switch-Input {
    param(
        [System.Windows.Forms.Form]$Form,
        $Button
    )

    $MonitorList = $Form.Tag.ListBox
    if ($MonitorList.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("No monitor selected. Items in list: $($MonitorList.Items.Count)", 'Monitor Input Switcher', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $monitor = $Form.Tag.Monitors[$MonitorList.SelectedIndex]
    $inputCode = [uint32]$Button.Tag
    $inputName = $Button.Text

    try {
        Set-MonitorInput -Monitor $monitor -InputCode $inputCode
        Log-Message -LogBox $Form.Tag.LogBox -Message "Switched '$($monitor.Description)' to $inputName."
    } catch {
        $errorMessage = $_.Exception.Message
        Log-Message -LogBox $Form.Tag.LogBox -Message "ERROR switching '$($monitor.Description)' to $($inputName): $errorMessage"
        [System.Windows.Forms.MessageBox]::Show("Failed to switch input. $errorMessage", 'Monitor Input Switcher', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

try {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
    $form = Build-Form
    Load-Monitors -Form $form
    [System.Windows.Forms.Application]::Run($form)
} finally {
    if ($form -and $form.Tag -and $form.Tag.Monitors) {
        Close-PhysicalMonitors -Monitors $form.Tag.Monitors
    }
}
