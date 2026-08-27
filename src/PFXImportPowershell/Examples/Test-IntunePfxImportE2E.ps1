#requires -Version 7.0

<#
.SYNOPSIS
Runs a non-production end-to-end Intune PFX import test.

.DESCRIPTION
NOT FOR PRODUCTION USE.

Creates a temporary ECC P-384 certificate and machine CNG key, creates or reuses
an Entra application, authenticates through the IntunePfxImport setup object,
imports the certificate record into Intune, reads it back, and removes temporary
artifacts by default.

The Entra application is intentionally retained for reuse. Use -KeepArtifacts
to retain the machine key, Intune record, and authentication context for
troubleshooting. The temporary PFX file is always deleted.

Run from an elevated PowerShell 7 session. The script can install Microsoft
Graph PowerShell modules for the current user and can open an admin-consent page.

.PARAMETER TargetUpn
Existing Microsoft Entra user in the authenticated tenant that receives the
temporary imported certificate record.

.PARAMETER ModulePath
Path to the IntunePfxImport module manifest.

.PARAMETER ApplicationDisplayName
Display name of the Entra application to create or reuse.

.PARAMETER ProviderName
Windows CNG provider used for the temporary machine encryption key.

.PARAMETER KeyName
Name of the temporary machine CNG encryption key.

.PARAMETER GrantAdminConsent
Opens the admin-consent page and pauses while the operator grants consent.

.PARAMETER KeepArtifacts
Retains the machine key, Intune record, and module authentication context.

.EXAMPLE
.\Test-IntunePfxImportE2E.ps1 -TargetUpn user@contoso.com

Runs the workflow and removes the temporary key, certificate, and Intune record.
The reusable Entra application remains in the tenant.

.NOTES
This sample changes a live tenant and the local machine. Review it before use.
Do not use it as production automation.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetUpn,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ModulePath = (Join-Path $PSScriptRoot '..\PFXImportPS\IntunePfxImport.psd1'),

    [string]$ApplicationDisplayName = 'Intune PFX Import E2E',

    [string]$ProviderName = 'Microsoft Software Key Storage Provider',

    [string]$KeyName = "IntunePfxImportE2E-$([Guid]::NewGuid().ToString('N'))",

    [switch]$GrantAdminConsent,

    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Warning 'NON-PRODUCTION SAMPLE: this script creates local and live-tenant test artifacts.'

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell session. Creating the machine CNG key requires administrator access.'
}

Import-Module $ModulePath -Force

if ($null -eq (Get-Command Initialize-IntunePfxImportApplication -ErrorAction SilentlyContinue)) {
    throw "The module at '$ModulePath' does not contain the Version 3 onboarding command."
}
$loadedModule = Get-Module -Name IntunePfxImport
if ($null -eq $loadedModule -or $loadedModule.Version -lt [version]'3.0.0') {
    throw "This E2E script requires IntunePfxImport 3.0.0 or later. Use the manifest and script module from the same release."
}

if (
    $null -eq (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue) -or
    $null -eq (Get-Command Get-MgApplication -ErrorAction SilentlyContinue)
) {
    Write-Host 'Installing Microsoft Graph PowerShell modules for the current user...'
    Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications -Scope CurrentUser -Force
}

$provider = New-Object Security.Cryptography.CngProvider($ProviderName)
$keyCreated = $false
if (-not [Security.Cryptography.CngKey]::Exists(
    $KeyName,
    $provider,
    [Security.Cryptography.CngKeyOpenOptions]::MachineKey)) {
    Write-Host "Creating machine CNG key '$ProviderName\$KeyName'..."
    Add-IntuneKspKey -ProviderName $ProviderName -KeyName $KeyName -Confirm:$false
    $keyCreated = $true
}
else {
    Write-Host "Reusing machine CNG key '$ProviderName\$KeyName'."
}

$certificate = $null
$ecdsa = $null
$record = $null
$recordImported = $false
$pfxPath = Join-Path ([IO.Path]::GetTempPath()) "IntunePfxImportE2E-$([Guid]::NewGuid()).pfx"
$passwordText = [Guid]::NewGuid().ToString('N')
$pfxPassword = ConvertTo-SecureString $passwordText -AsPlainText -Force

try {
    Write-Host "Generating an ECC P-384 certificate for '$TargetUpn'..."
    $ecdsa = [Security.Cryptography.ECDsa]::Create()
    $ecdsa.GenerateKey([Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP384'))
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        "CN=$TargetUpn",
        $ecdsa,
        [Security.Cryptography.HashAlgorithmName]::SHA384)

    $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $san.AddEmailAddress($TargetUpn)
    $request.CertificateExtensions.Add($san.Build())
    $request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
            $false,
            $false,
            0,
            $true))

    $certificate = $request.CreateSelfSigned(
        [DateTimeOffset]::UtcNow.AddMinutes(-5),
        [DateTimeOffset]::UtcNow.AddDays(7))
    $pfxBytes = $certificate.Export(
        [Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
        $passwordText)
    [IO.File]::WriteAllBytes($pfxPath, $pfxBytes)

    Write-Host "Creating or reusing Entra application '$ApplicationDisplayName'..."
    $setup = Initialize-IntunePfxImportApplication `
        -DisplayName $ApplicationDisplayName `
        -AuthenticationMode PublicClient `
        -ConnectGraph `
        -Confirm:$false

    if ($GrantAdminConsent) {
        Write-Host 'Opening the admin-consent page...'
        Start-Process $setup.AdminConsentUri
        Read-Host 'Grant consent in the browser, then press Enter to continue'
    }

    Write-Host 'Authenticating to Intune from the setup object...'
    Set-IntuneAuthenticationToken -Setup $setup -Confirm:$false

    Write-Host "Validating that '$TargetUpn' exists in the authenticated tenant..."
    Get-IntuneUserId -UPN $TargetUpn | Out-Null

    Write-Host 'Creating the imported PFX record. UPN is inferred from the certificate SAN...'
    $record = New-IntuneUserPfxCertificate `
        -PathToPfxFile $pfxPath `
        -PfxPassword $pfxPassword `
        -ProviderName $ProviderName `
        -KeyName $KeyName `
        -IntendedPurpose smimeEncryption `
        -PaddingScheme OaepSha512

    if ($record.UserPrincipalName -ne $TargetUpn) {
        throw "Certificate identity inference returned '$($record.UserPrincipalName)' instead of '$TargetUpn'."
    }
    if ($record.KeyAlgorithm -ne 'ecc') {
        throw "Expected the generated record to identify an ECC certificate but got '$($record.KeyAlgorithm)'."
    }

    Write-Host 'Importing the PFX record into Intune...'
    Import-IntuneUserPfxCertificate -CertificateList $record -Confirm:$false
    $recordImported = $true

    Write-Host 'Reading the record back from Intune...'
    $importedRecord = @(
        Get-IntuneUserPfxCertificate -UserThumbprintList ([pscustomobject]@{
            User = $TargetUpn
            Thumbprint = $record.Thumbprint
        })
    )
    if ($importedRecord.Count -ne 1) {
        throw "Expected one imported record but found $($importedRecord.Count)."
    }
    if ($importedRecord[0].UserPrincipalName -ne $TargetUpn) {
        throw "Expected persisted UPN '$TargetUpn' but got '$($importedRecord[0].UserPrincipalName)'."
    }
    if ($importedRecord[0].Thumbprint -ne $record.Thumbprint) {
        throw "Expected persisted thumbprint '$($record.Thumbprint)' but got '$($importedRecord[0].Thumbprint)'."
    }

    Write-Host ''
    Write-Host 'PASS: Intune PFX import E2E workflow completed successfully.' -ForegroundColor Green
    Write-Host "Application ID: $($setup.ApplicationId)"
    Write-Host "Certificate thumbprint: $($record.Thumbprint)"
}
finally {
    if (-not $KeepArtifacts -and $recordImported) {
        try {
            Write-Host 'Removing the imported Intune test record...'
            Remove-IntuneUserPfxCertificate -CertificateList $record -Confirm:$false
        }
        catch {
            Write-Warning "Could not remove the Intune test record: $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $pfxPath) {
        Remove-Item -LiteralPath $pfxPath -Force
    }
    if (-not $KeepArtifacts -and $keyCreated) {
        try {
            $cleanupKey = [Security.Cryptography.CngKey]::Open(
                $KeyName,
                $provider,
                [Security.Cryptography.CngKeyOpenOptions]::MachineKey)
            $cleanupKey.Delete()
            $cleanupKey.Dispose()
            Write-Host "Removed machine CNG key '$ProviderName\$KeyName'."
        }
        catch {
            Write-Warning "Could not remove the machine CNG key: $($_.Exception.Message)"
        }
    }
    if ($null -ne $certificate) { $certificate.Dispose() }
    if ($null -ne $ecdsa) { $ecdsa.Dispose() }
    if (-not $KeepArtifacts) {
        Remove-IntuneAuthenticationToken -Confirm:$false -ErrorAction SilentlyContinue
    }
    $passwordText = $null
}
