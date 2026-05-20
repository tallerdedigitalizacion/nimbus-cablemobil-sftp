[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Script:BaseDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:ConfigPath = Join-Path $Script:BaseDirectory "config.json"
$Script:Config = $null
$Script:LogFilePath = Join-Path $Script:BaseDirectory "logs\app.log"
$Script:IsConfigurationPhase = $true

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $Script:BaseDirectory $Path)
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string] $Level = "INFO"
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$timestamp] [$Level] $Message"
    $logDirectory = Split-Path -Parent $Script:LogFilePath
    Ensure-Directory -Path $logDirectory
    Add-Content -LiteralPath $Script:LogFilePath -Value $line -Encoding UTF8
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $Script:ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $Script:ConfigPath. Copy config.example.json to config.json and edit it."
    }

    try {
        return (Get-Content -LiteralPath $Script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        throw "Could not parse config.json: $($_.Exception.Message)"
    }
}

function Assert-RequiredConfig {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Config
    )

    $requiredFields = @(
        "winscpPath",
        "sftpHost",
        "sftpPort",
        "sftpUsername",
        "sftpPassword",
        "sftpRemoteDirectory",
        "filePattern",
        "localDownloadDirectory",
        "stateFile",
        "logFile",
        "smtpHost",
        "smtpPort",
        "smtpUseSsl",
        "smtpUsername",
        "smtpPassword",
        "mailFrom",
        "mailToPurchases",
        "mailToIT",
        "emailSubjectPrefix"
    )

    foreach ($field in $requiredFields) {
        if (-not ($Config.PSObject.Properties.Name -contains $field)) {
            throw "Missing required configuration field: $field"
        }

        $value = $Config.$field
        if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            throw "Configuration field cannot be empty: $field"
        }
    }

    if (-not (Test-Path -LiteralPath $Config.winscpPath -PathType Leaf)) {
        throw "WinSCP.com was not found at configured winscpPath: $($Config.winscpPath)"
    }

    if ([int]$Config.sftpPort -le 0 -or [int]$Config.sftpPort -gt 65535) {
        throw "sftpPort must be between 1 and 65535."
    }

    if ([int]$Config.smtpPort -le 0 -or [int]$Config.smtpPort -gt 65535) {
        throw "smtpPort must be between 1 and 65535."
    }
}

function ConvertTo-WinScpUrlComponent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    return [System.Uri]::EscapeDataString($Value)
}

function ConvertTo-WinScpQuotedValue {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    return '"' + ($Value -replace '"', '""') + '"'
}

function Invoke-WinScpDownload {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Config,

        [Parameter(Mandatory = $true)]
        [string] $DownloadDirectory
    )

    $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("nimbus-winscp-{0}.txt" -f ([System.Guid]::NewGuid().ToString("N")))
    $winscpLogPath = Join-Path (Split-Path -Parent $Script:LogFilePath) "winscp.log"

    $username = ConvertTo-WinScpUrlComponent -Value ([string]$Config.sftpUsername)
    $password = ConvertTo-WinScpUrlComponent -Value ([string]$Config.sftpPassword)
    $hostName = [string]$Config.sftpHost
    $port = [int]$Config.sftpPort
    $remoteDirectory = ConvertTo-WinScpQuotedValue -Value ([string]$Config.sftpRemoteDirectory)
    $localDirectory = ConvertTo-WinScpQuotedValue -Value $DownloadDirectory
    $pattern = ConvertTo-WinScpQuotedValue -Value ([string]$Config.filePattern)

    $winscpScript = @(
        "option batch abort",
        "option confirm off",
        "option failonnomatch off",
        "open `"sftp://$username`:$password@$hostName`:$port/`" -hostkey=*",
        "cd $remoteDirectory",
        "lcd $localDirectory",
        "get -filemask=`"*>=2D`" -preservetime $pattern",
        "exit"
    )

    try {
        Set-Content -LiteralPath $scriptPath -Value $winscpScript -Encoding ASCII
        Write-Log "Starting WinSCP download (Last 48h filter active) from ${hostName}:$port$($Config.sftpRemoteDirectory)."

        # /ini=nul avoids surprises from an interactive user's saved WinSCP profile.
        & $Config.winscpPath /ini=nul /script="$scriptPath" /log="$winscpLogPath" | ForEach-Object {
            Write-Log "WinSCP: $_"
        }

        if ($LASTEXITCODE -ne 0) {
            throw "WinSCP failed with exit code $LASTEXITCODE. See $winscpLogPath for details."
        }

        Write-Log "WinSCP download completed successfully."
    }
    finally {
        if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
            Remove-Item -LiteralPath $scriptPath -Force
        }
    }
}

function Read-SentState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFile
    )

    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return @()
    }

    try {
        $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $state) {
            return @()
        }
        if ($state -is [array]) {
            return @($state)
        }
        return @($state)
    }
    catch {
        throw "Could not read state file ${StateFile}: $($_.Exception.Message)"
    }
}

function Write-SentState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFile,

        [Parameter(Mandatory = $true)]
        [array] $State
    )

    $stateDirectory = Split-Path -Parent $StateFile
    Ensure-Directory -Path $stateDirectory

    if ($State.Count -eq 0) {
        "[]" | Set-Content -LiteralPath $StateFile -Encoding UTF8
        return
    }

    # Windows PowerShell 5.1 can serialize a single-item array as one object.
    # Build the JSON array explicitly so sent-files.json stays predictable.
    $items = @($State | ForEach-Object { $_ | ConvertTo-Json -Depth 5 })
    $json = "[`r`n" + ($items -join ",`r`n") + "`r`n]"
    $json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function New-SmtpClient {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Config
    )

    $client = [System.Net.Mail.SmtpClient]::new([string]$Config.smtpHost, [int]$Config.smtpPort)
    $client.EnableSsl = [bool]$Config.smtpUseSsl
    $client.Credentials = [System.Net.NetworkCredential]::new([string]$Config.smtpUsername, [string]$Config.smtpPassword)
    return $client
}

function Send-MailWithAttachment {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Config,

        [Parameter(Mandatory = $true)]
        [string] $To,

        [Parameter(Mandatory = $true)]
        [string] $Subject,

        [Parameter(Mandatory = $true)]
        [string] $Body,

        [string] $AttachmentPath
    )

    $message = [System.Net.Mail.MailMessage]::new()
    $client = $null
    $attachment = $null

    try {
        $message.From = [System.Net.Mail.MailAddress]::new([string]$Config.mailFrom)
        $message.To.Add($To)
        $message.Subject = $Subject
        $message.Body = $Body
        $message.IsBodyHtml = $false

        if (-not [string]::IsNullOrWhiteSpace($AttachmentPath)) {
            $attachment = [System.Net.Mail.Attachment]::new($AttachmentPath)
            $message.Attachments.Add($attachment)
        }

        $client = New-SmtpClient -Config $Config
        $client.Send($message)
    }
    finally {
        if ($null -ne $attachment) {
            $attachment.Dispose()
        }
        $message.Dispose()
        if ($null -ne $client) {
            $client.Dispose()
        }
    }
}

function Send-PurchaseEmail {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Config,

        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo] $File
    )

    $subject = "$($Config.emailSubjectPrefix) $($File.Name)"
    $body = @"
Nimbus Cablemobil SFTP automation downloaded a new invoice file and is forwarding it to purchases.

Timestamp: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
Machine: $env:COMPUTERNAME
Filename: $($File.Name)
Local path: $($File.FullName)
Size bytes: $($File.Length)
Log file: $Script:LogFilePath
"@

    Send-MailWithAttachment -Config $Config -To ([string]$Config.mailToPurchases) -Subject $subject -Body $body -AttachmentPath $File.FullName
}

function Send-ErrorEmail {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Config,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    $stackTrace = if ($null -ne $exception.StackTrace) { $exception.StackTrace } else { $ErrorRecord.ScriptStackTrace }

    $body = @"
Nimbus Cablemobil SFTP automation failed.

Timestamp: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
Machine: $env:COMPUTERNAME
Exception message: $($exception.Message)

Stack trace:
$stackTrace

Log file path:
$Script:LogFilePath
"@

    Send-MailWithAttachment -Config $Config -To ([string]$Config.mailToIT) -Subject "$($Config.emailSubjectPrefix) ERROR" -Body $body
}

try {
    $Script:Config = Read-Config
    
    # MODIFICACIÓN TRÓPICA: Forzamos el filtro estricto para procesar únicamente archivos .pdf
    $Script:Config.filePattern = "*.pdf"
    
    Assert-RequiredConfig -Config $Script:Config

    $Script:LogFilePath = Resolve-ProjectPath -Path ([string]$Script:Config.logFile)
    $downloadDirectory = Resolve-ProjectPath -Path ([string]$Script:Config.localDownloadDirectory)
    $stateFile = Resolve-ProjectPath -Path ([string]$Script:Config.stateFile)

    Ensure-Directory -Path $downloadDirectory
    Ensure-Directory -Path (Split-Path -Parent $Script:LogFilePath)

    $Script:IsConfigurationPhase = $false
    Write-Log "Run started."
    Invoke-WinScpDownload -Config $Script:Config -DownloadDirectory $downloadDirectory

    $sentState = @(Read-SentState -StateFile $stateFile)
    $sentFileNames = @{}
    foreach ($entry in $sentState) {
        if ($null -ne $entry.filename -and -not [string]::IsNullOrWhiteSpace([string]$entry.filename)) {
            $sentFileNames[[string]$entry.filename] = $true
        }
    }

    $downloadedFiles = @(Get-ChildItem -LiteralPath $downloadDirectory -File -Filter ([string]$Script:Config.filePattern) | Sort-Object Name)
    $newFiles = @($downloadedFiles | Where-Object { -not $sentFileNames.ContainsKey($_.Name) })

    if ($newFiles.Count -eq 0) {
        Write-Log "No new files found. Exiting successfully."
        exit 0
    }

    foreach ($file in $newFiles) {
        Write-Log "Sending file to purchases: $($file.Name)"
        Send-PurchaseEmail -Config $Script:Config -File $file

        $sentState += [pscustomobject]@{
            filename = $file.Name
            sentAt = (Get-Date).ToString("o")
            localPath = $file.FullName
            sizeBytes = $file.Length
        }
        Write-SentState -StateFile $stateFile -State $sentState
        $sentFileNames[$file.Name] = $true
        Write-Log "Marked file as sent: $($file.Name)"
    }

    Write-Log "Run completed successfully. Sent $($newFiles.Count) file(s)."
    exit 0
}
catch {
    $isConfigurationError = $Script:IsConfigurationPhase

    try {
        Write-Log $_.Exception.Message "ERROR"
    }
    catch {
        Write-Error $_.Exception.Message
    }

    if (-not $isConfigurationError -and $null -ne $Script:Config) {
        try {
            Send-ErrorEmail -Config $Script:Config -ErrorRecord $_
            Write-Log "Error email sent to IT." "ERROR"
        }
        catch {
            try {
                Write-Log "Failed to send error email to IT: $($_.Exception.Message)" "ERROR"
            }
            catch {
                Write-Error $_.Exception.Message
            }
        }
    }

    if ($isConfigurationError) {
        exit 2
    }

    exit 1
}