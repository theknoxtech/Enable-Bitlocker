<#
.SYNOPSIS

This script is used to enable Bitlocker.

.DESCRIPTION

This script is used to enable Bitlocker with TPM and Recovery Password protectors. It will also attempt to activate the TPM on Dell computers using the DellBiosProvider module.

Author: Jon Witherspoon
Last Modified: 08-14-24

.PARAMETER Name

None.

.INPUTS

None. You cannot pipe objects to this script.

.OUTPUTS

Console output of status or errors.
Log transcript.

.EXAMPLE

PS> .\Enable-Bitlocker.ps1

.LINK

None.

#>

# Global Variables
$global:LTSvc = "C:\Windows\LTSvc\packages"
$global:EncryptVol = Get-CimInstance -Namespace 'ROOT/CIMV2/Security/MicrosoftVolumeEncryption' -Class Win32_EncryptableVolume -Filter "DriveLetter='C:'"
<# $global:TPMStatus = Get-CimInstance -Namespace 'ROOT/CIMV2/Security/MicrosoftTPM' -Class Win32_TPM #>

# Creates a log entry in LTSvc\Packages\enable_bitlocker.txt
$Log = "$LTSvc\enable_bitlocker.txt"
enum Logs {
    Error
    Debug
    Info
}
function Add-LogEntry {
    
    Param(
    [string]$Message,
    [Logs]$Type
    )

    $timestamp = (Get-Date).ToString("MM/dd/yyyy HH:mm:ss")

    switch ($Type) {
        ([Logs]::Debug) {Add-Content $Log "$timestamp DEBUG: $message"; break  }
        ([Logs]::Error) {Add-Content $Log "$timestamp ERROR: $message"; break }
        ([Logs]::Info) {Add-Content $Log "$timestamp INFO: $message"; break}
        (default) {Add-Content $Log "$timestamp []: $message"} 
    }
}

# BIOS verion check
function Get-SMBiosVersion {
    $Bios = Get-CimInstance Win32_BIOS 
    $Version = [float]::Parse("$($bios.SMBIOSMajorVersion).$($bios.SMBIOSMinorVersion)")
    return $Version
}

# Returns true if BIOS version does not meet minium requirements. Returns false otherwise.
function Get-SMBiosRequiresUpgrade {
    Param(
        [float]$MinimumVersion = 2.4
    )
  
    if ((Get-SMBiosVersion) -lt $MinimumVersion) {
        return $true
    }
  
    return $false
}

##
# TODO Review Get-TPMState Function 
##
# Query TPM and return custom TPMState object <[bool]IsPresent, [bool]IsReady, [bool]IsEnabled, [function]CheckTPMReady>
<# ($TPMStatus | Invoke-CimMethod -MethodName "IsReady").IsReady
($TPMStatus | Invoke-CimMethod -MethodName "IsEnabled").IsEnabled
($TPMStatus | Invoke-CimMethod -MethodName "Isactivated").IsActivated #>
function Get-TPMState {

    $TPM = Get-Tpm

    $TPMState = New-Object psobject
    $TPMState | Add-Member NoteProperty "IsPresent" $TPM.TpmPresent
    $TPMState | Add-Member NoteProperty "IsReady" $TPM.TpmReady
    $TPMState | Add-Member NoteProperty "IsEnabled" $TPM.TpmEnabled

    $TPMState | Add-Member ScriptMethod "CheckTPMReady" {
        if ($this.IsPresent -and $this.IsReady -and $this.IsEnabled) {
            return $true
        }

        return $false
    }

    return $TPMState
}

# Query Bitlocker and return custom Get-BitlockerState object 
function Get-BitlockerState {
    $ERGBitlocker = Get-BitLockerVolume -MountPoint "C:"

    $BitlockerState = New-Object psobject
    $BitlockerState | Add-Member NoteProperty "VolumeStatus" $ERGBitlocker.VolumeStatus
    $BitlockerState | Add-Member NoteProperty "ProtectionStatus" $ERGBitlocker.ProtectionStatus
    $BitlockerState | Add-Member NoteProperty "KeyProtector" $ERGBitlocker.KeyProtector
    
    $BitlockerState | Add-Member ScriptMethod "IsTPMKeyPresent" {
        $tpm_key = ($this.KeyProtector).KeyProtectorType
        
        if ($tpm_key -contains "Tpm"){
            return $true
        }else {
            return $false
        }
     }
     $BitlockerState | Add-Member ScriptMethod "IsRecoveryPassword" {
        $recovery_password = ($this.KeyProtector).KeyProtectorType

        if ($recovery_password -contains "RecoveryPassword"){
            return $true
        }else {
            return $false
        }
     }
     $BitlockerState | Add-Member ScriptMethod "IsRebootRequired" {
        $reboot_status = ($EncryptVol | Invoke-CimMethod -MethodName "GetSuspendCount").SuspendCount

        if ($reboot_status -gt 0){
            return $true
        }else{
            return $false
        }
     }
     $BitlockerState | Add-Member ScriptMethod "IsVolumeEncrypted" {
        $encrypt_status = ($EncryptVol | Invoke-CimMethod -MethodName "GetConversionStatus").conversionstatus
        
        if ($encrypt_status -eq 0){
            return $false
        }elseif ($encrypt_status -eq 1){
            return $true
        }

     }
     $BitlockerState | Add-Member ScriptMethod "IsProtected" {
        $protection_status = ($EncryptVol | Invoke-CimMethod -MethodName "GetProtectionStatus").protectionstatus

        if ($protection_status -eq 0){
            return $false
        }elseif($protection_status -eq 1){
            return $true
        }

     }
    return $BitlockerState
}

# Query Bitlocker and Set-BitlockerState
function Set-BitlockerState {
    $tpm = Get-TPMState
    $encrypt_state = Get-BitlockerState

    $bitlocker_options = @{

        MountPoint       = "C:"
        EncryptionMethod = "XtsAes128"
        TpmProtector     = $true
        UsedSpaceOnly    = $true
        SkiphardwareTest = $true

    }

    if ((!($encrypt_state.IsVolumeEncrypted())) -and $tpm.CheckTPMReady()) {

        try {
            
            Enable-Bitlocker @bitlocker_options
        }
        catch {

            throw "Bitlocker was not enabled. Check TPM and try again." 
        }   
    }

}

# Check if Visual C++ Redistributables are installed and if not install Visual C++ 2010 and Visual C++ 2015-2022
# TODO Add error handling here
function Install-Redistributables {
   
  
    $products = Get-CimInstance win32_product
 

    # Visual C++ 2010 Redistributable
  
    if (($products | Where-Object { $_.name -like "Microsoft Visual C++ 2010*" })) {
    
        Add-LogEntry -Type Info -Message "Microsoft Visual C++ 2010 already installed"
    }
    
    else {
       
        Add-LogEntry -Debug -Message "Installing Microsoft Visual C++ 2010"

        $working_dir = $PWD

        [System.NET.WebClient]::new().DownloadFile("https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe", "$($LTSvc)\vcredist_2010_x64.exe")
        Set-Location $LTSvc
        .\vcredist_2010_x64.exe /extract:vc2010 /q 
        Start-Sleep -Seconds 1.5
        Set-Location $LTSvc\vc2010
        .\Setup.exe /q | Wait-Process
    
        Set-Location $working_dir

        Add-LogEntry -Type Info -Message "Visual C++ 2010 has been installed"
    }
    # Visual C++ 2022 Redistributable
 
    if (($products | Where-Object { $_.name -like "Microsoft Visual C++ 2022*" })) {

        Add-LogEntry -Type Info -Message "Microsoft Visual C++ 2022 already installed"

    }
   
    else {
        
        Add-LogEntry -Type Debug -Message "Installing Visual C++ 2022"

        $working_dir = $PWD

        [System.NET.WebClient]::new().DownloadFile("https://aka.ms/vs/17/release/vc_redist.x64.exe", "$($LTSvc)\vc_redist.x64.exe")
        Set-Location $LTSvc
        .\vc_redist.x64.exe /q | Wait-Process
    
        Set-Location $working_dir

        Add-LogEntry -Type Info -Message "Microsoft Visual C++ 2022 has been installed"
    }
}

# Visual C++ Redistributable 2010
<# function Install-VCRedist2010 {
    $working_dir = $PWD

    [System.NET.WebClient]::new().DownloadFile("https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe", "$($LTSvc)\vcredist_2010_x64.exe")
    Set-Location $LTSvc
    .\vcredist_2010_x64.exe /extract:vc2010 /q 
    Start-Sleep -Seconds 1.5
    Set-Location $LTSvc\vc2010
    .\Setup.exe /q | Wait-Process

    Set-Location $working_dir
} #>

# Visual C++ Redistributable 2015-2022
<# function Install-VCRedist2022 {
    $working_dir = $PWD

    [System.NET.WebClient]::new().DownloadFile("https://aka.ms/vs/17/release/vc_redist.x64.exe", "$($LTSvc)\vc_redist.x64.exe")
    Set-Location $LTSvc
    .\vc_redist.x64.exe /q | Wait-Process

    Set-Location $working_dir
} #>

# Returns current password value as a [Bool]
function IsBIOSPasswordSet {
    return [System.Convert]::ToBoolean((Get-Item -Path DellSmBios:\Security\IsAdminpasswordSet).CurrentValue)
}

# Generates a random passowrd from Dinopass to pass to Set-BiosAdminPassword
# Replaces symbols with "_"
function GenerateRandomPassword {
    Param(
        [switch]$SaveToFile
    )

    $password = (Invoke-WebRequest -Uri "https://www.dinopass.com/password/strong").Content 
    $replaced_password = $password -replace "\W", '_'

    if ($SaveToFile) {

        $replaced_password | Out-File $LTSvc\BiosPW.txt 
    }
    
    return $replaced_password
}

# Update Set-BiosAdminPassword function with GenerateRandomPassword
function Set-BiosAdminPassword {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Password
    )
    $Password = Get-Content $LTSvc\BiosPW.txt 

    Set-Item -Path DellSmBios:\Security\AdminPassword $Password

}

# Remove BIOS admin password
function Remove-BiosAdminPassword {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$RemovePassword
    )
    
    Set-Item -Path DellSmbios:\Security\AdminPassword ""  -Password $CurrentPW


}

# Add either a recovery password or TPM key protector
function Add-KeyProtector {
    param(
        [switch]$RecoveryPassword,
        [switch]$TPMProtector
    )

    if ($RecoveryPassword) {
        Add-BitLockerKeyProtector -MountPoint "C:" -RecoveryPasswordProtector
    }elseif ($TPMProtector) {
        Add-BitLockerKeyProtector -MountPoint "C:" -TpmProtector
    }

}


# Check if TPM Security is enabled in the BIOS - Returns True or False
function IsTPMSecurityEnabled {
        
    return (Get-Item -Path DellSmbios:\TPMSecurity\TPMSecurity).CurrentValue
}

# Check if TPM is Activated in the BIOS - Returns Enabled or Disabled
function IsTPMActivated {

    return (Get-Item -Path DellSmbios:\TPMSecurity\TPMActivation).CurrentValue
}



# Convert exception to string, match for Hresult code and return it
function Get-ExceptionCode {

    param (
        [String]$errorcode
    )
    
    $regex = "\((0x[0-9A-Fa-f]+)\)"

    if ($errorcode.ToString() -match $regex) {

        $code = $Matches[1]
        return $code
    }

}


    $bitlocker_status = Get-BitlockerState
    $TPMState = Get-TPMState
    $bitlocker_settings = @{
    
        "IsRebootPending" = $bitlocker_status.IsRebootRequired()
        "Encrypted" = $bitlocker_status.IsVolumeEncrypted()
        "TPMProtectorExists" = $bitlocker_status.IsTPMKeyPresent()
        "RecoveryPasswordExists" = $bitlocker_status.IsRecoveryPassword()
        "Protected" = $bitlocker_status.IsProtected()
        "TPMReady" = $TPMState.CheckTPMReady()
    }



    switch ($bitlocker_settings) {
        {$_.Protected -eq $false} {
            try {
                Resume-BitLocker -MountPoint c: -ErrorAction Stop
            }
            catch [System.Runtime.InteropServices.COMException] {
                Add-LogEntry -Type Error -Message $_.Exception.Message
                 # Attempt to encrypt drive
                #$errorcode = ($_.Exception.Message).ToString()
               
                if (Get-ExceptionCode -errorcode $_.Exception.Message -contains "0x80310001") {
                    
                Set-BitlockerState
                Add-KeyProtector -RecoveryPassword
                Resume-BitLocker -MountPoint C:

                Add-LogEntry -Type Info -Message "Bitlocker has been enabled"
    
                }else {
                    
                    Add-LogEntry -Type Error -Message $_.Exception.Message
                }
            
                
            }
          }
     
    }