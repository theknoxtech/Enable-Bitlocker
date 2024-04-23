#Global Storage Path
$LTSvc = "C:\Windows\LTSvc\packages"

#Start Transcript
Start-Transcript -Path $LTSvc -Verbose

#Bitlocker Check
function IsVolumeEncrypted {
    Param(
        [Parameter(Mandatory=$true)]
        [char]$DriveLetter
    )

    $volume_status = (Get-BitLockerVolume -MountPoint "$($DriveLetter):" -ErrorAction SilentlyContinue).VolumeStatus

    if ($volume_status -eq "FullyEncrypted" -or $volume_status -eq "EncryptionInProgress")
    {
        return $true
    }

    return $false
}

#Bios verion check
function Get-SMBiosVersion {
    $Bios = Get-CimInstance Win32_BIOS 
    $Version = [float]::Parse("$($bios.SMBIOSMajorVersion).$($bios.SMBIOSMinorVersion)")
    return $Version
}

# Returns true if BIOS version does not meet minium requirements. Returns False otherwise.
function Get-SMBiosRequiresUpgrade
{
    Param(
    [float]$MinimumVersion = 2.4
  )
  
  if ((Get-SMBiosVersion) -lt $MinimumVersion){
    return $true
  }
  
  return $false
}


# Query TPM and return custom TPMState object <[bool]IsPresent, [bool]IsReady, [bool]IsEnabled, [function]CheckTPMReady>
function Get-TPMState {

    $TPM = Get-Tpm

    $TPMState = New-Object psobject
    $TPMState | Add-Member NoteProperty "IsPresent" $TPM.TpmPresent
    $TPMState | Add-Member NoteProperty "IsReady" $TPM.TpmReady
    $TPMState | Add-Member NoteProperty "IsEnabled" $TPM.TpmEnabled

    $TPMState | Add-Member ScriptMethod "CheckTPMReady" {
        if ($this.IsPresent -and $this.IsReady -and $this.IsEnabled)
        {
            return $true
        }

        return $false
    }

    return $TPMState
}

# Check if C++ Runtimes are installed and if not install C++ 2010 and C++ 2015-2022
function VCChecks {
    # C++ Runtime Logic
    # Check for c++ redistribution packages
    Write-Host "Loading installed applications..." -ForegroundColor Yellow
    $products = Get-CimInstance win32_product
    Write-Host "Complete" -ForegroundColor Green

    # C++ 2010 Redistributable
    Write-Host "Checking for 'Microsoft Visual C++ 2010 Redistributable'..." -ForegroundColor Yellow
    if (($products | Where-Object { $_.name -like "Microsoft Visual C++ 2010*Redistributable*" })) {
        Write-Host "`tVC 2010 Redistributable detected!" -ForegroundColor Green
    }
    # Handle install logic
    else {
        Write-Host "`tInstalling Microsoft Visual C++ 2010 Redistributable..." -ForegroundColor Yellow
        Install-VCRedist2010
        Write-Host "`tComplete" -ForegroundColor Green
    }

    # C++ 2022 Redistributable
    Write-Host "Checking for 'Microsoft Visual C++ 2022 Runtime'..." -ForegroundColor Yellow
    if (($products | Where-Object { $_.name -like "Microsoft Visual C++ 2022*" })) {
        Write-Host "`tVC 2022 Runtime detected!" -ForegroundColor Green
    }
    # Handle install logic
    else {
        Write-Host "`tInstalling Microsoft Visual C++ 2022 Runtime..." -ForegroundColor Yellow
        Install-VCRedist2022
        Write-Host "`tComplete" -ForegroundColor Green
    }
}



#Redistributable 2010
function Install-VCRedist2010 {
    $working_dir = $PWD

    [System.NET.WebClient]::new().DownloadFile("https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe", "$($LTSvc)\vcredist_2010_x64.exe")
    Set-Location $LTSvc
    .\2010vc_redist_x64.exe /extract:vc2010 /q | Wait-Process
    Set-Location $LTSvc\vc2010
    .\Setup.exe /q | Wait-Process

    Set-Location $working_dir
}

#Redistributable 2015-2022
function Install-VCRedist2022 {
    $working_dir = $PWD

    Start-BitsTransfer -Source "https://aka.ms/vs/17/release/vc_redist.x64.exe" -Destination "$($LTSvc)\vc_redist.x64.exe"
    Set-Location $LTSvc
    .\vc_redist.x64.exe /q | Wait-Process

    Set-Location $working_dir
}

function IsBIOSPasswordSet
{
    return (Get-Item -Path DellSmBios:\Security\IsAdminpasswordSet).CurrentValue
}

function GenerateRandomPassword
{
    Param(
        [switch]$SaveToFile
    )

    $password = (Invoke-WebRequest -Uri "https://www.dinopass.com/password/strong").Content

    if($SaveToFile)
    {
        $password | Out-File $LTSvc\BiosPW.txt
    }
    
    return $password
}

#TODO Update Set-BiosAdminPassword function with GenerateRandomPassword
function Set-BiosAdminPassword {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Password
    )
    if ($PwdCheck -eq $false) {
        $Password = Get-Content $LTSvc\BiosPW.txt
        Set-Item -Path DellSmBios:\Security\AdminPassword $Password
    }
    else {
        Get-ComputerInfo | Select-Object -ExpandProperty CsName | Out-File c:\temp\bitlockerpwlog.txt -append
        return "Bios password detected it's borked"
    }

}

#If volume is unencrypted and TPM is ready then enable Bitlocker
function Set-ERGBitlocker {

    $tpm = Get-TPMState

    $bitlocker_options = @{

        MountPoint       = "C:"
        EncryptionMethod = "XtsAes128"
        TpmProtector     = $true
        UsedSpaceOnly    = $true
        SkiphardwareTest  = $true

    }

    if ((!(IsVolumeEncrypted)) -and $tpm.CheckTPMReady()) {

        try {
            
            Enable-Bitlocker @bitlocker_options
        }
        catch {

            throw "Bitlocker was not enabled. Check TPM and try again" 
        }   
    }

}

# If Bitlocker is enabled, then add recovery password protector
#TODO Add check for existing key?
function Add-RecoveryKeyProtector {
    
    if (IsVolumeEncrypted) {
        Add-BitLockerKeyProtector -MountPoint "C:" -RecoveryPasswordProtector
    }
}

# Check if TPM Security is enabled in the BIOS
function IsTPMSecurityEnabled {
    $tpm = Get-TPMState

    if (!($tpm.CheckTPMReady())){
        (Get-Item -Path DellSmbios:\TPMSecurity\TPMSecurity).CurrentValue
    }
    return IsTPMSecurityEnabled

}



###SCRIPTFUNCTIONS###

# Execution Policy Check
if (Get-ExecutionPolicy -ne "Unrestricted" -and Get-ExecutionPolicy -ne "Bypass")
{
    try {
        Set-ExecutionPolicy Bypass
    }
    catch {
        throw "ExecutionPolicy prohibits this script from running: Update ExecutionPolicy and run again"
    }
}


# BIOS Version
    # Upgrade BIOS if not up to date
    if (Get-SMBiosRequiresUpgrade)
    {
        throw "BIOS Version does not meet minimum requirements: Upgrade BIOS Version"
    }


# Bitlocker Validation
# If Bitlocker is enabled, abort with success!
# TODO Does a return need to be put here
if (IsVolumeEncrypted -DriveLetter C)
{
    Write-Host "Bitlocker Enabled! Exiting script" -ForegroundColor Green
    
}
else {
    Write-Host "Bitlocker not enabled" -ForegroundColor Red
    
}



# TPM Logic if Bitlocker not Enabled
$TPMState = Get-TPMState
if ($TPMState.CheckTPMReady())
{
    Write-Host "TPM is Ready!" -ForegroundColor Green
}
#TODO TPM Logic if Bitlocker not Enabled
#TODO: Write logic to enable / repair TPM using Dell BIOS package
else {
    throw "TPM requires modification: $($TPMState)"
}

# C++ Runtime Libraries
VCChecks

#Install DellBiosProvider

if (!(Get-SMBiosRequiresUpgrade) -and $TPMState.CheckTPMReady()){

    try {
        Install-Module -Name DellBiosProvider -Force
        Import-Module DellBiosProvider -Verbose
    }
    catch {
        throw "DellBiosProvider was NOT installed. Please try again."
    }

}



# Set BIOS Password
if (IsBIOSPasswordSet)
{
    throw "BIOS Password already set: Clear BIOS password before proceeding"
}
else
{
    Set-BiosAdminPassword -Password (GenerateRandomPassword -SaveToFile)
}




#TODO# Enable Bitlocker
#TODO        # Backup Bitlocker key
#TODO    # Remove BIOS Password
#TODO    # Delete BiosPW.txt file