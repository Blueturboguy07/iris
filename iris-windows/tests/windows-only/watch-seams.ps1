# watch-seams.ps1
#
# A by-hand smoke test for the three Windows-only seams the watch executor
# (src/services/autopilot/watch.ts) relies on. The vitest suite fakes every OS
# call, so it can never exercise the real PowerShell one-liners — this script is
# how they get run on the Windows VM (or a Windows dev box) before shipping.
#
# It prints, for whatever window is in the FOREGROUND when it runs:
#   1. the foreground process (the foregroundApp seam)
#   2. the active browser tab URL over UI Automation (the urlHost seam)
#   3. whether a UI Automation element matching a label is present (the axElement seam)
#
# HOW TO RUN. Bring the window you want to probe to the front, then from another
# window (or a countdown) run:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-only\watch-seams.ps1
#
# To give yourself time to focus a browser first, pass -DelaySeconds:
#
#   powershell ... -File tests\windows-only\watch-seams.ps1 -DelaySeconds 4 -AxLabel "address"
#
# The one-liners here are kept behaviourally identical to what watch.ts builds
# in buildForegroundProcessCommand / buildActiveBrowserUrlCommand /
# buildAxElementQueryCommand. If you change those, change these to match, and
# re-run this to confirm the real shape still reads the machine.

param(
    [int]$DelaySeconds = 0,
    [string]$AxLabel = "address"
)

if ($DelaySeconds -gt 0) {
    Write-Host "Focus the window you want to probe. Reading in $DelaySeconds seconds..."
    Start-Sleep -Seconds $DelaySeconds
}

Add-Type -Namespace IrisFg -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr h, out int pid);
'@

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$foregroundWindow = [IrisFg.Win]::GetForegroundWindow()

# --- 1. foreground process ------------------------------------------------
Write-Host "== foreground process =="
$foregroundPid = 0
[void][IrisFg.Win]::GetWindowThreadProcessId($foregroundWindow, [ref]$foregroundPid)
$foregroundProcess = Get-Process -Id $foregroundPid -ErrorAction SilentlyContinue
if ($foregroundProcess) {
    Write-Host ("{0}|{1}.exe" -f $foregroundProcess.Id, $foregroundProcess.ProcessName)
} else {
    Write-Host "(no foreground process could be read)"
}

# --- 2. active browser tab URL -------------------------------------------
Write-Host "== active browser tab URL (UI Automation) =="
$printedUrl = $false
if ($foregroundWindow -ne [System.IntPtr]::Zero) {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($foregroundWindow)
    if ($root) {
        $editCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Edit)
        $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
        foreach ($edit in $edits) {
            $name = $edit.Current.Name
            if ($name -match "address" -or $name -match "search or enter" -or $name -match "enter address") {
                $valuePattern = $null
                if ($edit.TryGetCurrentPattern(
                        [System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
                    Write-Host ("URL|" + $valuePattern.Current.Value)
                    $printedUrl = $true
                    break
                }
            }
        }
    }
}
if (-not $printedUrl) {
    Write-Host "(no address-bar element found — foreground window is probably not a browser; watch.ts falls back to the window title)"
}

# --- 3. axElement lookup --------------------------------------------------
Write-Host ("== axElement lookup for label '{0}' ==" -f $AxLabel)
$foundAxElement = $false
if ($foregroundWindow -ne [System.IntPtr]::Zero) {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($foregroundWindow)
    if ($root) {
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($element in $all) {
            $name = $element.Current.Name
            $type = $element.Current.LocalizedControlType
            if ($name -like ("*" + $AxLabel + "*") -or $type -like ("*" + $AxLabel + "*")) {
                Write-Host ("AX|1  (matched name='{0}' type='{1}')" -f $name, $type)
                $foundAxElement = $true
                break
            }
        }
    }
}
if (-not $foundAxElement) {
    Write-Host ("(no UI Automation element matched '{0}')" -f $AxLabel)
}
