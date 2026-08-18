# ====================================================================
#  SharedUtils.ps1 - 共用工具庫 v2.0.1
# ====================================================================

# --------------------------------------------------------------------
# 1. 環境解密引擎檢測 (含來源與 x86/x64 識別)
# --------------------------------------------------------------------
function Get-EnvironmentCapabilities {
    [CmdletBinding()]
    param (
        [string]$RootDir
    )

    $engineDir = Join-Path $RootDir "engine"
    $is64Bit   = [Environment]::Is64BitProcess
    $archDir   = if ($is64Bit) { "x64" } else { "x86" }

    # ----------------------------------------------------------------
    # 1. 搜尋 UnRAR
    # ----------------------------------------------------------------
    $unrarPath = $null
    $unrarSource = "未找到"
    $unrarArch = $null

    $localUnrar = Join-Path $engineDir "unrar\$archDir\unrar.exe"
    $localUnrarAlt = Join-Path $engineDir "unrar/$(if($is64Bit){'x86'}else{'x64'})\unrar.exe"

    if (Test-Path $localUnrar) {
        $unrarPath = $localUnrar
        $unrarSource = "隨附引擎 (Local)"
        $unrarArch = $archDir
    } elseif (Test-Path $localUnrarAlt) {
        $unrarPath = $localUnrarAlt
        $unrarSource = "隨附引擎 (Local)"
        $unrarArch = if ($is64Bit) { "x86" } else { "x64" }
    } else {
        $sysUnrar = Get-Command "unrar.exe" -ErrorAction SilentlyContinue
        if ($sysUnrar) {
            $unrarPath = $sysUnrar.Source
            $unrarSource = "系統安裝 (System)"
            $unrarArch = if ($unrarPath -match "(x86|SysWOW64)") { "x86" } else { "x64" }
        }
    }

    # ----------------------------------------------------------------
    # 2. 搜尋 7-Zip
    # ----------------------------------------------------------------
    $sevenZipPath = $null
    $sevenZipSource = "未找到"
    $sevenZipArch = $null

    $local7z = Join-Path $engineDir "7z\$archDir\7z.exe"
    $local7zAlt = Join-Path $engineDir "7z/$(if($is64Bit){'x86'}else{'x64'})\7z.exe"

    if (Test-Path $local7z) {
        $sevenZipPath = $local7z
        $sevenZipSource = "隨附引擎 (Local)"
        $sevenZipArch = $archDir
    } elseif (Test-Path $local7zAlt) {
        $sevenZipPath = $local7zAlt
        $sevenZipSource = "隨附引擎 (Local)"
        $sevenZipArch = if ($is64Bit) { "x86" } else { "x64" }
    } else {
        $sys7z = Get-Command "7z.exe" -ErrorAction SilentlyContinue
        if ($sys7z) {
            $sevenZipPath = $sys7z.Source
            $sevenZipSource = "系統安裝 (System)"
            $sevenZipArch = if ($sevenZipPath -match "(x86|SysWOW64)") { "x86" } else { "x64" }
        }
    }

    # ----------------------------------------------------------------
    # 3. 搜尋 SharpCompress
    # ----------------------------------------------------------------
    $sharpCompressPath = $null
    $sharpCompressSource = "未找到"
    $scSubDir = if ($PSVersionTable.PSEdition -eq 'Core') { "netstandard2.0" } else { "net48" }
    
    $localDll = Join-Path $engineDir "sharpcompress\$scSubDir\SharpCompress.dll"
    if (Test-Path $localDll) {
        $sharpCompressPath = $localDll
        $sharpCompressSource = "隨附 DLL ($scSubDir)"
    }

    # 自動嘗試載入
    if ($sharpCompressPath -and (Test-Path $sharpCompressPath)) {
        try {
            Add-Type -Path $sharpCompressPath -ErrorAction Stop
        } catch {}
    }

    return @{
        UnRarPath           = $unrarPath
        UnRarStatus         = if ($unrarPath) { "可用" } else { "未找到" }
        UnRarSource         = $unrarSource
        UnRarArch           = $unrarArch

        SevenZipPath        = $sevenZipPath
        SevenZipStatus      = if ($sevenZipPath) { "可用" } else { "未找到" }
        SevenZipSource      = $sevenZipSource
        SevenZipArch        = $sevenZipArch

        SharpCompressPath   = $sharpCompressPath
        SharpCompressStatus = if ($sharpCompressPath) { "可用" } else { "未找到" }
        SharpCompressSource = $sharpCompressSource
    }
}

# --------------------------------------------------------------------
# 2. 計算檔案 MD5 哈希值
# --------------------------------------------------------------------
function Get-FileMD5Hash {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) { return $null }

    $md5 = [System.Security.Cryptography.MD5]::Create()
    $stream = [System.IO.File]::OpenRead($FilePath)
    try {
        $hashBytes = $md5.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").ToLower()
    }
    finally {
        $stream.Close()
        $stream.Dispose()
        $md5.Dispose()
    }
}

# --------------------------------------------------------------------
# 3. Checkpoint 進度檔讀寫 (A/B 雙備份原子化機制)
# --------------------------------------------------------------------
function Get-ValidCheckpoint {
    [CmdletBinding()]
    param (
        [string]$RootDir,
        [string]$ArchiveType,
        [string]$CurrentArchiveMD5,
        [string]$CurrentDictMD5
    )

    $cpDir = Join-Path $RootDir "checkpoint"
    if (-not (Test-Path $cpDir)) {
        return @{ Status = "NOT_FOUND"; Data = $null }
    }

    $fileA = Join-Path $cpDir "$($ArchiveType)_checkpoint_A.json"
    $fileB = Join-Path $cpDir "$($ArchiveType)_checkpoint_B.json"

    $validData = $null

    foreach ($file in @($fileA, $fileB)) {
        if (Test-Path $file) {
            try {
                $jsonContent = Get-Content -Path $file -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($jsonContent.ArchiveMD5 -eq $CurrentArchiveMD5 -and $jsonContent.DictionaryMD5 -eq $CurrentDictMD5) {
                    $validData = $jsonContent
                    break
                }
            } catch {}
        }
    }

    if ($null -ne $validData) {
        return @{ Status = "VALID"; Data = $validData }
    } else {
        return @{ Status = "NOT_FOUND"; Data = $null }
    }
}

function Save-AtomicCheckpoint {
    [CmdletBinding()]
    param (
        [string]$RootDir,
        [string]$ArchiveType,
        [hashtable]$Data
    )

    $cpDir = Join-Path $RootDir "checkpoint"
    if (-not (Test-Path $cpDir)) {
        [void](New-Item -ItemType Directory -Path $cpDir -Force)
    }

    $fileA = Join-Path $cpDir "$($ArchiveType)_checkpoint_A.json"
    $fileB = Join-Path $cpDir "$($ArchiveType)_checkpoint_B.json"

    $jsonString = $Data | ConvertTo-Json -Depth 5

    # A/B 輪流原子化寫入
    try {
        [System.IO.File]::WriteAllText($fileA, $jsonString, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($fileB, $jsonString, [System.Text.Encoding]::UTF8)
    } catch {}
}

function Clear-CheckpointFiles {
    [CmdletBinding()]
    param (
        [string]$RootDir,
        [string]$ArchiveType
    )

    $cpDir = Join-Path $RootDir "checkpoint"
    $fileA = Join-Path $cpDir "$($ArchiveType)_checkpoint_A.json"
    $fileB = Join-Path $cpDir "$($ArchiveType)_checkpoint_B.json"

    Remove-Item -Path $fileA, $fileB -ErrorAction SilentlyContinue
}