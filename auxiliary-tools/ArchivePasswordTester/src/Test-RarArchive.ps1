# ====================================================================
#  Test-RarArchive.ps1 - RAR 格式專屬解密子腳本 v2.5 (支援自動匯出 Log 紀錄檔)
# ====================================================================

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [Parameter(Mandatory = $true)]
    [string]$ArchiveMD5,

    [Parameter(Mandatory = $true)]
    [string]$DictionaryPath,

    [Parameter(Mandatory = $true)]
    [string]$DictionaryMD5,

    [Parameter(Mandatory = $true)]
    [int64]$TotalPasswords,

    [Parameter(Mandatory = $true)]
    [int]$Threads,

    [Parameter(Mandatory = $true)]
    [int64]$StartIndex,

    [Parameter(Mandatory = $true)]
    [hashtable]$EngineEnv
)

# 載入共用庫
$sharedUtilsPath = Join-Path $PSScriptRoot "SharedUtils.ps1"
if (Test-Path $sharedUtilsPath) { . $sharedUtilsPath }

# 1. 決定優先調用的解密引擎
$unrarExe = $EngineEnv.UnrarPath
$sevenZipExe = $EngineEnv.SevenZipPath

if (-not $unrarExe -and -not $sevenZipExe) {
    Write-Host "[ERROR] 未檢測到可用的 UnRAR 或 7-Zip 解密引擎！" -ForegroundColor Red
    Read-Host "請按 Enter 鍵離開..."
    return
}

# 2. 初始化共享狀態
$sharedState = [hashtable]::Synchronized(@{
    Found             = $false
    FoundPassword     = $null
    TestedCount       = $StartIndex
    LastCheckpoint    = $StartIndex
    CancelRequested   = $false
})

$runspacePool = [runspacefactory]::CreateRunspacePool(1, $Threads)
$runspacePool.Open()

# 3. Worker 腳本塊
$workerScript = {
    param (
        [string]$UnrarPath,
        [string]$SevenZipPath,
        [string]$TargetArchive,
        [string[]]$PasswordBatch,
        [int64]$BatchStartIndex,
        [hashtable]$SharedState
    )

    $successPassword = $null

    foreach ($pwd in $PasswordBatch) {
        if ($SharedState.Found -or $SharedState.CancelRequested) { break }

        $isSuccess = $false

        try {
            # 優先嘗試 1: UnRAR Engine (-p Password -t Test Archive)
            if ($UnrarPath) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $UnrarPath
                $psi.Arguments = "t -p`"$pwd`" -idq -inul `"$TargetArchive`""
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true

                $process = [System.Diagnostics.Process]::Start($psi)
                $process.WaitForExit()

                if ($process.ExitCode -eq 0) { $isSuccess = $true }
            }
            # 備用嘗試 2: 7-Zip Engine (t -pPassword)
            elseif ($SevenZipPath) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $SevenZipPath
                $psi.Arguments = "t -p`"$pwd`" `"$TargetArchive`""
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true

                $process = [System.Diagnostics.Process]::Start($psi)
                $process.WaitForExit()

                if ($process.ExitCode -eq 0) { $isSuccess = $true }
            }
        }
        catch {}

        if ($isSuccess) {
            [System.Threading.Monitor]::Enter($SharedState.SyncRoot)
            try {
                if (-not $SharedState.Found) {
                    $SharedState.Found = $true
                    $SharedState.FoundPassword = $pwd
                }
            }
            finally {
                [System.Threading.Monitor]::Exit($SharedState.SyncRoot)
            }
            break
        }
    }

    return @{
        BatchSize = $PasswordBatch.Length
        Success   = $isSuccess
        Password  = $pwd
    }
}

# 4. 讀取密碼檔案
$allPasswords = [System.IO.File]::ReadAllLines($DictionaryPath, [System.Text.Encoding]::UTF8)

# 平滑動態批次
$batchSize = 10
if ($TotalPasswords -gt 500)   { $batchSize = 20 }
if ($TotalPasswords -gt 5000)  { $batchSize = 30 }
if ($TotalPasswords -gt 50000) { $batchSize = 50 }

$currentIndex = $StartIndex
$runningJobs = New-Object System.Collections.Generic.List[hashtable]

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$startTime = Get-Date
$lastSaveTime = [System.DateTime]::Now

# 攔截 Ctrl+C 事件並改為請求中斷確認
[System.Console]::TreatControlCAsInput = $true

Clear-Host
$archiveName = Split-Path $ArchivePath -Leaf
$dictName    = Split-Path $DictionaryPath -Leaf
$engineName  = if ($unrarExe) { Split-Path $unrarExe -Leaf } else { Split-Path $sevenZipExe -Leaf }

# 5. 主迴圈
try {
    while ($true) {
        if ($sharedState.Found -or $sharedState.CancelRequested) { break }
        if ($currentIndex -ge $TotalPasswords -and $runningJobs.Count -eq 0) { break }

        # 監聽鍵盤輸入 (按 Q 或 Ctrl+C 觸發中斷確認)
        if ([System.Console]::KeyAvailable) {
            $key = [System.Console]::ReadKey($true)
            if ($key.Key -eq [System.ConsoleKey]::Q -or ($key.Modifiers -band [System.ConsoleModifiers]::Control -and $key.Key -eq [System.ConsoleKey]::C)) {
                
                [System.Console]::SetCursorPosition(0, 15)
                Write-Host ""
                Write-Host "====================================================================" -ForegroundColor Yellow
                $confirm = Read-Host "[?] 偵測到中斷請求，請問是否要暫停解密並儲存進度？ (Y/N)"
                Write-Host "====================================================================" -ForegroundColor Yellow

                if ($confirm -eq "Y" -or $confirm -eq "y") {
                    $sharedState.CancelRequested = $true
                    break
                } else {
                    Clear-Host
                }
            }
        }

        # 派發工作
        while ($runningJobs.Count -lt $Threads -and $currentIndex -lt $TotalPasswords) {
            $takeCount = [System.Math]::Min($batchSize, $TotalPasswords - $currentIndex)
            
            $batch = New-Object string[] $takeCount
            [System.Array]::Copy($allPasswords, $currentIndex, $batch, 0, $takeCount)

            $powershell = [powershell]::Create()
            $powershell.RunspacePool = $runspacePool
            [void]$powershell.AddScript($workerScript)
            [void]$powershell.AddArgument($unrarExe)
            [void]$powershell.AddArgument($sevenZipExe)
            [void]$powershell.AddArgument($ArchivePath)
            [void]$powershell.AddArgument($batch)
            [void]$powershell.AddArgument($currentIndex)
            [void]$powershell.AddArgument($sharedState)

            $asyncResult = $powershell.BeginInvoke()

            $runningJobs.Add(@{
                PowerShell  = $powershell
                AsyncResult = $asyncResult
                Count       = $takeCount
                EndIndex    = ($currentIndex + $takeCount)
            })

            $currentIndex += $takeCount
        }

        # 檢查 Job
        for ($i = $runningJobs.Count - 1; $i -ge 0; $i--) {
            $job = $runningJobs[$i]
            if ($job.AsyncResult.IsCompleted) {
                try {
                    $result = $job.PowerShell.EndInvoke($job.AsyncResult)
                } catch {}
                $job.PowerShell.Dispose()

                $sharedState.TestedCount += $job.Count

                # 每 1000 筆或每 10 秒自動同步 Checkpoint
                if (($job.EndIndex - $sharedState.LastCheckpoint) -ge 1000 -or ([System.DateTime]::Now - $lastSaveTime).TotalSeconds -ge 10) {
                    $cpData = @{
                        ArchiveMD5      = $ArchiveMD5
                        DictionaryMD5   = $DictionaryMD5
                        LastTestedIndex = $job.EndIndex
                        UpdatedTime     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    }
                    Save-AtomicCheckpoint -RootDir $PSScriptRoot\.. -ArchiveType "rar" -Data $cpData
                    $sharedState.LastCheckpoint = $job.EndIndex
                    $lastSaveTime = [System.DateTime]::Now
                }

                $runningJobs.RemoveAt($i)
            }
        }

        # ----------------------------------------------------------------
        # UI 動態繪製
        # ----------------------------------------------------------------
        $pctVal = if ($TotalPasswords -gt 0) { [math]::Round(($sharedState.TestedCount / $TotalPasswords) * 100, 2) } else { 100 }
        $pctStr = "$pctVal%".PadRight(25)
        
        $elapsedStr = $stopwatch.Elapsed.ToString("hh\:mm\:ss").PadRight(25)
        
        $speedVal = if ($stopwatch.Elapsed.TotalSeconds -gt 0) {
            [int](($sharedState.TestedCount - $StartIndex) / $stopwatch.Elapsed.TotalSeconds)
        } else { 0 }
        $speedStr = "$speedVal 筆/秒".PadRight(25)
        
        $triedStr = "$($sharedState.TestedCount) / $TotalPasswords".PadRight(25)
        $threadStr = "$Threads 個啟動中".PadRight(25)
        $engineStr = "UnRAR/7-Zip ($engineName)".PadRight(25)

        [System.Console]::SetCursorPosition(0, 0)
        Write-Host "====================================================================" -ForegroundColor Cyan
        Write-Host "                        解密測試進行中 (RAR)                        " -ForegroundColor Cyan
        Write-Host "====================================================================" -ForegroundColor Cyan
        Write-Host " 目標檔案 : $archiveName" -ForegroundColor White
        Write-Host " 線程數量 : $threadStr" -ForegroundColor White
        Write-Host " 解密引擎 : $engineStr" -ForegroundColor White
        Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
        Write-Host " 測試進度 : $pctStr" -ForegroundColor Yellow
        Write-Host " 測試速度 : $speedStr" -ForegroundColor White
        Write-Host " 已測數量 : $triedStr" -ForegroundColor White
        Write-Host " 累積耗時 : $elapsedStr" -ForegroundColor White
        Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
        Write-Host " [提示] 按 'Q' 鍵可隨時暫停測試並儲存進度紀錄                            " -ForegroundColor DarkGray
        Write-Host "====================================================================" -ForegroundColor Cyan

        Start-Sleep -Milliseconds 80
    }
}
finally {
    # 恢復原本的 Ctrl+C 行為
    [System.Console]::TreatControlCAsInput = $false
    $stopwatch.Stop()

    foreach ($job in $runningJobs) {
        try {
            $job.PowerShell.Stop()
            $job.PowerShell.Dispose()
        } catch {}
    }
    $runspacePool.Close()
    $runspacePool.Dispose()

    Clear-Host
    Write-Host "====================================================================" -ForegroundColor Cyan
    Write-Host "                        解密測試結果結算 (RAR)                        " -ForegroundColor Cyan
    Write-Host "====================================================================" -ForegroundColor Cyan

    $resultText = ""
    $passwordText = "(無)"

    if ($sharedState.Found) {
        $resultText = "[成功] 成功破譯密碼"
        $passwordText = $sharedState.FoundPassword

        Write-Host "[★] 恭喜！成功破譯密碼！" -ForegroundColor Green
        Write-Host "    └── 密碼為: $passwordText" -ForegroundColor Yellow
        Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
        Write-Host " 總耗時   : $($stopwatch.Elapsed.ToString("hh\:mm\:ss"))" -ForegroundColor White
        Write-Host " 測試位置 : 第 $($sharedState.TestedCount) 筆" -ForegroundColor White
        
        Clear-CheckpointFiles -RootDir $PSScriptRoot\.. -ArchiveType "rar"
    }
    elseif ($sharedState.CancelRequested) {
        $resultText = "[中斷] 使用者主動暫停測試，已儲存 Checkpoint 進度。"

        Write-Host "[!] 使用者已主動中斷測試。" -ForegroundColor Yellow
        Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
        Write-Host " 已測試   : $($sharedState.TestedCount) / $TotalPasswords 筆" -ForegroundColor White
        Write-Host " 耗時     : $($stopwatch.Elapsed.ToString("hh\:mm\:ss"))" -ForegroundColor White

        $cpData = @{
            ArchiveMD5      = $ArchiveMD5
            DictionaryMD5   = $DictionaryMD5
            LastTestedIndex = $sharedState.TestedCount
            UpdatedTime     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
        Save-AtomicCheckpoint -RootDir $PSScriptRoot\.. -ArchiveType "rar" -Data $cpData
        Write-Host "[系統] 進度紀錄檔已完整寫入，下次執行將自動繼續測試。" -ForegroundColor Green
    }
    else {
        $resultText = "[失敗] 字典中的所有密碼皆已測試完畢，無一命中。"

        Write-Host "[X] 解密失敗：字典中的所有密碼皆已測試完畢，無一命中。" -ForegroundColor Red
        Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
        Write-Host " 總耗時 : $($stopwatch.Elapsed.ToString("hh\:mm\:ss"))" -ForegroundColor White
        Clear-CheckpointFiles -RootDir $PSScriptRoot\.. -ArchiveType "rar"
    }

    # ------------------------------------------------------------------
    # 寫入 Log 紀錄檔
    # ------------------------------------------------------------------
    try {
        $logDir = Join-Path $PSScriptRoot "..\logs"
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $logFileName = "Log_Rar_$($startTime.ToString('yyyyMMdd_HHmmss')).log"
        $logPath = Join-Path $logDir $logFileName

        $avgSpeed = if ($stopwatch.Elapsed.TotalSeconds -gt 0) {
            [int](($sharedState.TestedCount - $StartIndex) / $stopwatch.Elapsed.TotalSeconds)
        } else { 0 }

        $logContent = @"
====================================================================
                    解密測試紀錄 (RAR Archive)
====================================================================
測試時間   : $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))
目標檔案   : $archiveName
檔案 MD5   : $ArchiveMD5
字典檔案   : $dictName
字典 MD5   : $DictionaryMD5
解密引擎   : UnRAR/7-Zip ($engineName)
使用的線程 : $Threads
--------------------------------------------------------------------
字典總筆數 : {0:N0} 筆
實際測試數 : {1:N0} 筆
測試總耗時 : {2}
平均速度   : {3:N0} 筆/秒
--------------------------------------------------------------------
測試結果   : $resultText
解密密碼   : $passwordText
====================================================================
"@ -f $TotalPasswords, $sharedState.TestedCount, $stopwatch.Elapsed.ToString("hh\:mm\:ss"), $avgSpeed

        [System.IO.File]::WriteAllText($logPath, $logContent, [System.Text.Encoding]::UTF8)
        Write-Host "[Log] 測試紀錄已成功輸出至: $logFileName" -ForegroundColor Gray
    }
    catch {
        Write-Host "[WARN] 寫入 Log 紀錄檔時發生錯誤: $_" -ForegroundColor Yellow
    }

    Write-Host "====================================================================" -ForegroundColor Cyan
    Write-Host ""
    Read-Host "測試完成，請按 Enter 鍵離開..."
}