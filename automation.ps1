<#
.SYNOPSIS
    One-command runner for the RetailCo ETL on Windows.

.DESCRIPTION
    Wraps main.py and the dashboard so the whole project can be run, or scheduled, from PowerShell.

    Actions:
      install     create .venv (if missing) and install requirements.txt
      setup       python main.py setup     (create RETAIL_STG and RETAIL_DWH, run once)
      extract     python main.py extract   (download the source CSV into the inbox)
      run         python main.py run       (inbox -> RETAIL_STG -> RETAIL_DWH -> archive)
      report      python main.py report    (business queries -> output/report_<env>.md)
      all         install, setup, extract, run, report
      dashboard   streamlit run dashboard/streamlit_app.py
      schedule    register a daily Windows scheduled task that runs "run" at -At (default 02:30)
      unschedule  remove that scheduled task

.EXAMPLE
    .\automation.ps1 all
    .\automation.ps1 run -Env prod
    .\automation.ps1 schedule -At 02:30
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("install", "setup", "extract", "run", "report", "all", "dashboard", "schedule", "unschedule")]
    [string]$Action = "run",

    [string]$Env,

    [string]$At = "02:30"
)

$ErrorActionPreference = "Stop"
$ProjectFolder = $PSScriptRoot
$VenvPython = Join-Path $ProjectFolder ".venv\Scripts\python.exe"
$TaskName = "RetailCo ETL"
$LogFolder = Join-Path $ProjectFolder "output\logs"

function Get-Python {
    if (Test-Path $VenvPython) { return $VenvPython }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw "Python not found. Install Python 3.11+ or run '.\automation.ps1 install'." }
    return $python.Source
}

function Invoke-Install {
    if (-not (Test-Path $VenvPython)) {
        Write-Host "Creating virtual environment .venv"
        & python -m venv (Join-Path $ProjectFolder ".venv")
        if ($LASTEXITCODE -ne 0) { throw "Could not create .venv" }
    }
    & $VenvPython -m pip install --upgrade pip
    & $VenvPython -m pip install -r (Join-Path $ProjectFolder "requirements.txt")
    if ($LASTEXITCODE -ne 0) { throw "pip install failed" }
}

function Invoke-Main([string]$Command) {
    $arguments = @((Join-Path $ProjectFolder "main.py"), $Command)
    if ($Env) { $arguments += @("--env", $Env) }

    New-Item -ItemType Directory -Force $LogFolder | Out-Null
    $logFile = Join-Path $LogFolder ("{0}_{1:yyyyMMdd_HHmmss}.log" -f $Command, (Get-Date))

    Write-Host "== $Command ==  (log: $logFile)"
    Push-Location $ProjectFolder
    try {
        & (Get-Python) @arguments 2>&1 | Tee-Object -FilePath $logFile
        $code = $LASTEXITCODE
    }
    finally { Pop-Location }

    if ($code -ne 0) { throw "$Command failed with exit code $code (see $logFile)" }
}

try {
    switch ($Action) {
        "install"   { Invoke-Install }
        "all"       {
            Invoke-Install
            foreach ($step in "setup", "extract", "run", "report") { Invoke-Main $step }
        }
        "dashboard" {
            Push-Location $ProjectFolder
            try { & (Get-Python) -m streamlit run dashboard/streamlit_app.py }
            finally { Pop-Location }
        }
        "schedule"  {
            $scriptPath = Join-Path $ProjectFolder "automation.ps1"
            $taskArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" run' -f $scriptPath
            if ($Env) { $taskArguments += " -Env $Env" }
            $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArguments -WorkingDirectory $ProjectFolder
            $trigger = New-ScheduledTaskTrigger -Daily -At $At
            $taskSettings = @{
                TaskName    = $TaskName
                Action      = $taskAction
                Trigger     = $trigger
                Description = "Nightly RetailCo ETL load (automation.ps1 run)"
                Force       = $true
            }
            Register-ScheduledTask @taskSettings | Out-Null
            Write-Host "Scheduled task '$TaskName' runs daily at $At."
        }
        "unschedule" {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Host "Scheduled task '$TaskName' removed."
        }
        default     { Invoke-Main $Action }
    }
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
