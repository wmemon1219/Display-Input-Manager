[CmdletBinding()]
param()

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --------------------------------------------------------------------
# Simple Loading Screen (neutral theme)
# --------------------------------------------------------------------
$global:LoadingForm = $null

function Show-LoadingScreen {
    try {
        if ($global:LoadingForm -and -not $global:LoadingForm.IsDisposed) { return }

        # Create the form
        $global:LoadingForm = New-Object System.Windows.Forms.Form
        $global:LoadingForm.FormBorderStyle = 'FixedDialog'
        $global:LoadingForm.StartPosition   = 'CenterScreen'
        $global:LoadingForm.BackColor       = [System.Drawing.Color]::White
        $global:LoadingForm.Width           = 420
        $global:LoadingForm.Height          = 150
        $global:LoadingForm.MaximizeBox     = $false
        $global:LoadingForm.MinimizeBox     = $false
        $global:LoadingForm.ShowInTaskbar   = $false
        $global:LoadingForm.TopMost         = $true
        $global:LoadingForm.Text            = "HP Display Input Manager"

        # Create the label
        $label = New-Object System.Windows.Forms.Label
        $label.Text      = "Loading HP Display Input Manager..."
        $label.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
        $label.AutoSize  = $true
        $label.ForeColor = [System.Drawing.Color]::Black
        $label.Location  = New-Object System.Drawing.Point(10, 30)
        $global:LoadingForm.Controls.Add($label)

        # Create the progress bar
        $progress = New-Object System.Windows.Forms.ProgressBar
        $progress.Style                 = 'Continuous'
        $progress.MarqueeAnimationSpeed = 30
        $progress.Width                 = 340
        $progress.Height                = 18
        $progress.Location              = New-Object System.Drawing.Point(30, 70)
        $progress.Minimum               = 0
        $progress.Maximum               = 100

        # Set initial color of the progress bar (background color)
        $progress.BackColor = [System.Drawing.Color]::Gray
        $progress.ForeColor = [System.Drawing.Color]::Green  # Green color for progress

        $global:LoadingForm.Controls.Add($progress)

        # Show the loading form
        $global:LoadingForm.Show()
        
        # Simulate the progress
        for ($i = 0; $i -le 100; $i++) {
            $progress.Value = $i
            [System.Windows.Forms.Application]::DoEvents()  # Allow UI updates
            Start-Sleep -Milliseconds 50  # Simulate loading
        }

        # Do events to ensure the form is responsive
        [System.Windows.Forms.Application]::DoEvents()

    } catch {}
}

function Close-LoadingScreen {
    try {
        if ($global:LoadingForm -and -not $global:LoadingForm.IsDisposed) {
            $global:LoadingForm.Close()
        }
    } catch {}
}



function Show-ErrorBox {
    param(
        [string]$Message,
        [string]$Title = "HP Display Input Manager"
    )
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

# --------------------------------------------------------------------
# Execution Policy / HPCMSL / Display Discovery
# --------------------------------------------------------------------
try {
    $currentPolicy = Get-ExecutionPolicy -Scope Process
    if ($currentPolicy -eq 'Restricted' -or $currentPolicy -eq 'AllSigned') {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
    }
} catch {}

if (-not (Get-Module -ListAvailable -Name HPCMSL)) {
    Show-ErrorBox "HPCMSL module not found. Install HPCMSL (HP Client Management Script Library) and re-run."
    return
}

Show-LoadingScreen

try {
    Import-Module HPCMSL -ErrorAction Stop
}
catch {
    Close-LoadingScreen
    Show-ErrorBox ("Unable to import HPCMSL: {0}" -f $_.Exception.Message)
    return
}

try {
    $displays = Get-HPDisplay -ErrorAction Stop
}
catch {
    Close-LoadingScreen
    Show-ErrorBox ("Unable to query HP displays: {0}" -f $_.Exception.Message)
    return
}

if (-not $displays) {
    Close-LoadingScreen
    Show-ErrorBox "No HP-supported displays detected."
    return
}

# Model-specific options (you can extend this map as needed)
$InputOptionsByModel = @{
    'OMEN 34c G2' = @('DP1','DP2','HDMI1','HDMI2')
    'HP 724pu'    = @('DP1','DP2','HDMI1','HDMI2')
    'HP E27q G5'  = @('DP1','DP2','HDMI1','HDMI2')
}
$BaseInputOptions = @('DP1','DP2','HDMI1','HDMI2')

function Get-InputOptionsForDisplay {
    param(
        [Parameter(Mandatory)]
        $Display
    )
    if ($InputOptionsByModel.ContainsKey($Display.ModelName)) {
        return $InputOptionsByModel[$Display.ModelName]
    }
    return $BaseInputOptions
}

# Check if AutoSleepMode parameter exists in this HPCMSL version
$script:SetHpDisplayCommand = Get-Command Set-HPDisplay -ErrorAction SilentlyContinue
$script:SupportsAutoSleep   = $false
if ($script:SetHpDisplayCommand -and
    $script:SetHpDisplayCommand.Parameters.ContainsKey('AutoSleepMode')) {
    $script:SupportsAutoSleep = $true
}

# --------------------------------------------------------------------
# Main Form
# --------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "HP Display Input Manager"
$form.Size = New-Object System.Drawing.Size(760, 480)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::WhiteSmoke
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.FormBorderStyle = 'FixedSingle'   # enables minimize, still non-resizable
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.KeyPreview  = $true

# Title
$title = New-Object System.Windows.Forms.Label
$title.Text = "HP Display Input Manager"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::DarkBlue
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(150, 20)
$form.Controls.Add($title)

# Display selection
$labelDisplay = New-Object System.Windows.Forms.Label
$labelDisplay.Text = "Select Display:"
$labelDisplay.AutoSize = $true
$labelDisplay.Location = New-Object System.Drawing.Point(40, 80)
$form.Controls.Add($labelDisplay)

$comboDisplay = New-Object System.Windows.Forms.ComboBox
$comboDisplay.Location = New-Object System.Drawing.Point(180, 75)
$comboDisplay.Width = 420
$comboDisplay.DropDownStyle = 'DropDownList'
$form.Controls.Add($comboDisplay)

foreach ($d in $displays) {
    $name = if ($d.ModelName) {
        "{0} (SN: {1})" -f $d.ModelName, $d.SerialNumber
    } else {
        "Unknown Display (SN: {0})" -f $d.SerialNumber
    }
    [void]$comboDisplay.Items.Add($name)
}
$comboDisplay.SelectedIndex = 0

# Auto Input group
$groupAutoInput = New-Object System.Windows.Forms.GroupBox
$groupAutoInput.Text = "Auto Input (binary)"
$groupAutoInput.Location = New-Object System.Drawing.Point(40, 120)
$groupAutoInput.Size = New-Object System.Drawing.Size(260, 100)
$form.Controls.Add($groupAutoInput)

$radioAutoOn = New-Object System.Windows.Forms.RadioButton
$radioAutoOn.Text = "Enable (1)"
$radioAutoOn.AutoSize = $true
$radioAutoOn.Location = New-Object System.Drawing.Point(15, 25)
$groupAutoInput.Controls.Add($radioAutoOn)

$radioAutoOff = New-Object System.Windows.Forms.RadioButton
$radioAutoOff.Text = "Disable (0)"
$radioAutoOff.AutoSize = $true
$radioAutoOff.Location = New-Object System.Drawing.Point(15, 50)
$groupAutoInput.Controls.Add($radioAutoOff)

# Auto Sleep checkbox
$checkAutoSleep = New-Object System.Windows.Forms.CheckBox
$checkAutoSleep.Text = "Auto Sleep Enabled"
$checkAutoSleep.AutoSize = $true
$checkAutoSleep.Location = New-Object System.Drawing.Point(340, 160)
$form.Controls.Add($checkAutoSleep)

# Active input dropdown
$labelInput = New-Object System.Windows.Forms.Label
$labelInput.Text = "Active Input:"
$labelInput.AutoSize = $true
$labelInput.Location = New-Object System.Drawing.Point(40, 245)
$form.Controls.Add($labelInput)

$comboInput = New-Object System.Windows.Forms.ComboBox
$comboInput.Location = New-Object System.Drawing.Point(180, 240)
$comboInput.Width = 200
$comboInput.DropDownStyle = 'DropDownList'
$form.Controls.Add($comboInput)

# Quick input group
$groupQuick = New-Object System.Windows.Forms.GroupBox
$groupQuick.Text = "Quick Input"
$groupQuick.Location = New-Object System.Drawing.Point(500, 220)
$groupQuick.Size = New-Object System.Drawing.Size(220, 160)
$form.Controls.Add($groupQuick)

# Status label
$labelStatus = New-Object System.Windows.Forms.Label
$labelStatus.Text = ""
$labelStatus.AutoSize = $true
$labelStatus.Location = New-Object System.Drawing.Point(40, 330)
$labelStatus.ForeColor = [System.Drawing.Color]::Green
$form.Controls.Add($labelStatus)

# Quick buttons
$script:selectedQuickInput = $null

function Build-QuickInputButtons {
    param(
        [System.Windows.Forms.GroupBox]$Group,
        [string[]]$Inputs
    )

    $Group.Controls.Clear()
    $script:selectedQuickInput = $null

    $y = 28
    foreach ($inp in $Inputs) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text   = $inp
        $btn.Width  = 140
        $btn.Height = 28
        $btn.Left   = 35
        $btn.Top    = $y
        $btn.Font   = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

        $btn.Add_Click({
            param($sender,$args)
            $script:selectedQuickInput = $sender.Text
            $labelStatus.Text = "Selected Input: $($sender.Text)"
            $labelStatus.ForeColor = [System.Drawing.Color]::Green
        })

        $Group.Controls.Add($btn)
        $y += 32
    }
}

# Centered Apply button
$buttonApply = New-Object System.Windows.Forms.Button
$buttonApply.Text = "Apply Settings"
$buttonApply.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$buttonApply.Width  = 200
$buttonApply.Height = 40
$buttonApply.Left   = [int](($form.ClientSize.Width - $buttonApply.Width) / 2)
$buttonApply.Top    = 340
$buttonApply.BackColor = [System.Drawing.Color]::LightSteelBlue
$buttonApply.ForeColor = [System.Drawing.Color]::Black
$buttonApply.FlatStyle = 'Flat'
$form.Controls.Add($buttonApply)

# Optional footer
$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = 'Bottom'
$footer.Height = 22
$footer.BackColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($footer)

$footerLabel = New-Object System.Windows.Forms.Label
$footerLabel.Text = "Powered by HPCMSL HP HERO Lab"
$footerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
$footerLabel.ForeColor = [System.Drawing.Color]::DimGray
$footerLabel.AutoSize = $true
$footerLabel.Location = New-Object System.Drawing.Point(8, 4)
$footer.Controls.Add($footerLabel)

# --------------------------------------------------------------------
# Logic: Refresh + Apply
# --------------------------------------------------------------------
function Refresh-InputsForDisplay {
    $comboInput.Items.Clear()
    $script:selectedQuickInput = $null

    $idx = $comboDisplay.SelectedIndex
    if ($idx -lt 0) { return }

    $display = $displays[$idx]
    $inputs  = Get-InputOptionsForDisplay -Display $display

    foreach ($i in $inputs) {
        [void]$comboInput.Items.Add($i)
    }
    if ($comboInput.Items.Count -gt 0) {
        $comboInput.SelectedIndex = 0
    }

    Build-QuickInputButtons -Group $groupQuick -Inputs $inputs
}

function Refresh-DisplaySettings {
    $idx = $comboDisplay.SelectedIndex
    if ($idx -lt 0) { return }

    $display = $displays[$idx]

    $groupAutoInput.Enabled = $false
    $checkAutoSleep.Enabled = $false

    $radioAutoOn.Checked  = $false
    $radioAutoOff.Checked = $false
    $checkAutoSleep.Checked = $false

    # AutoInputEnabled
    if ($display.PSObject.Properties.Match("AutoInputEnabled").Count -gt 0) {
        if ($display.AutoInputEnabled -ne $null -and $display.AutoInputEnabled -ne "N/A") {
            $groupAutoInput.Enabled = $true
            if ($display.AutoInputEnabled -eq $true -or $display.AutoInputEnabled -eq 1) {
                $radioAutoOn.Checked = $true
            } else {
                $radioAutoOff.Checked = $true
            }
        }
    }

    # AutoSleepMode (only if supported by this HPCMSL)
    if ($script:SupportsAutoSleep -and
        $display.PSObject.Properties.Match("AutoSleepMode").Count -gt 0) {

        if ($display.AutoSleepMode -ne $null -and $display.AutoSleepMode -ne "N/A") {
            $checkAutoSleep.Enabled = $true
            if ($display.AutoSleepMode -eq "On") {
                $checkAutoSleep.Checked = $true
            } else {
                $checkAutoSleep.Checked = $false
            }
        }
    } else {
        $checkAutoSleep.Enabled = $false
        $checkAutoSleep.Checked = $false
    }

    Refresh-InputsForDisplay

    if ($display.PSObject.Properties.Match("ActiveInput").Count -gt 0) {
        $currentInput = [string]$display.ActiveInput
        if ($currentInput -and $comboInput.Items.Contains($currentInput)) {
            $comboInput.SelectedItem = $currentInput
            $labelStatus.Text = "Current Input: $currentInput"
            $labelStatus.ForeColor = [System.Drawing.Color]::Green
        } else {
            $labelStatus.Text = ""
        }
    }
}

function Apply-Settings {
    $idx = $comboDisplay.SelectedIndex
    if ($idx -lt 0) { return }

    $display = $displays[$idx]
    $errors  = @()

    # Auto Input (1/0)
    if ($groupAutoInput.Enabled) {
        try {
            $bin = if ($radioAutoOn.Checked) { 1 } else { 0 }
            Set-HPDisplay -SerialNumber $display.SerialNumber -AutoInputEnabled $bin
        }
        catch {
            $errors += "Auto Input: $($_.Exception.Message)"
        }
    }

    # Auto Sleep (only if parameter exists)
    if ($checkAutoSleep.Enabled -and $script:SupportsAutoSleep) {
        try {
            $val = if ($checkAutoSleep.Checked) { "On" } else { "Off" }
            Set-HPDisplay -SerialNumber $display.SerialNumber -AutoSleepMode $val
        }
        catch {
            $errors += "Auto Sleep: $($_.Exception.Message)"
        }
    }

    # Active Input
    $inputToApply = if ($script:selectedQuickInput) { $script:selectedQuickInput } else { $comboInput.SelectedItem }
    if ($inputToApply) {
        try {
            Set-HPDisplay -SerialNumber $display.SerialNumber -ActiveInput $inputToApply
            $labelStatus.Text = "Settings applied successfully."
            $labelStatus.ForeColor = [System.Drawing.Color]::Green
        }
        catch {
            $errors += "Active Input: $($_.Exception.Message)"
        }
    }

    if ($errors.Count -gt 0) {
        Show-ErrorBox ("Error applying settings:`n{0}" -f ($errors -join "`n"))
    }
}

# --------------------------------------------------------------------
# Events + simple numeric hotkeys (while form is focused)
# --------------------------------------------------------------------
$comboDisplay.Add_SelectedIndexChanged({ Refresh-DisplaySettings })
$buttonApply.Add_Click({ Apply-Settings })

$form.Add_KeyDown({
    param($sender,$e)
    switch ($e.KeyCode) {
        'D1' { $script:selectedQuickInput = "DP1";    $labelStatus.Text = "Selected Input: DP1";    Apply-Settings; $e.Handled = $true }
        'D2' { $script:selectedQuickInput = "DP2";    $labelStatus.Text = "Selected Input: DP2";    Apply-Settings; $e.Handled = $true }
        'D3' { $script:selectedQuickInput = "HDMI1";  $labelStatus.Text = "Selected Input: HDMI1";  Apply-Settings; $e.Handled = $true }
        'D4' { $script:selectedQuickInput = "HDMI2";  $labelStatus.Text = "Selected Input: HDMI2";  Apply-Settings; $e.Handled = $true }
    }
})

# --------------------------------------------------------------------
# Initialize and show
# --------------------------------------------------------------------
Refresh-DisplaySettings
Close-LoadingScreen
[void]$form.ShowDialog()
