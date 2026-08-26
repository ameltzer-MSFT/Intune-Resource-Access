# Intune PFX Import PowerShell module

Version 4.0 is a PowerShell script module for creating and managing Microsoft Intune `userPFXCertificate` records. It no longer builds, loads, or exports compiled PowerShell cmdlets. The retained `EncryptionUtilities` project is used only by `OnPremValidation`; it is not a module dependency.

## Requirements

- Windows PowerShell 5.1 with .NET Framework 4.7.2, or PowerShell 7 on Windows.
- A Microsoft Entra application registration with `DeviceManagementConfiguration.ReadWrite.All`, `User.Read.All`, and (for delegated authentication) `User.Read`. Grant admin consent.
- A Windows CNG provider for local key operations. `Microsoft Software Key Storage Provider` is suitable for development. Run operational key commands under an account permitted to use the machine key.

The module runs under PowerShell 7, but CNG key operations are Windows-only. No credentials, tenant settings, or cloud endpoints are stored in the manifest.

## One-command Entra application onboarding

Version 4.0 can create or validate the tenant-specific application registration instead of requiring manual manifest edits. The onboarding function uses the current Microsoft Graph PowerShell SDK (`Microsoft.Graph.Authentication` and `Microsoft.Graph.Applications`), not AzureAD or MSOnline cmdlets.

The operator needs a Graph SDK connection with `Application.ReadWrite.All` and `Application.Read.All`. Application Administrator or Cloud Application Administrator can create and configure an app registration. When `ClientSecret` or `Both` configures Microsoft Graph **application permissions**, only a Privileged Role Administrator or Global Administrator can grant tenant-wide admin consent.

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Import-Module .\PFXImportPS\IntunePfxImport.psd1

$setup = Initialize-IntunePfxImportApplication `
    -DisplayName 'Intune PFX Import' `
    -AuthenticationMode Both `
    -CreateClientSecret `
    -ConnectGraph
```

The function creates or reuses an app registration and service principal, configures application `DeviceManagementConfiguration.ReadWrite.All` and `User.Read.All`, and configures delegated `DeviceManagementConfiguration.ReadWrite.All`, `User.Read.All`, and `User.Read` when `PublicClient` or `Both` is selected. It also configures the native redirect URI and public-client flow for device-code and legacy ROPC compatibility. An exact display-name match is reused; multiple matches cause an error. Use `-ExistingApplicationId` to select an existing registration deterministically.

The Graph SDK caller cannot silently grant admin consent. For `ClientSecret` or `Both`, open `$setup.AdminConsentUri` as a Privileged Role Administrator or Global Administrator, review the requested permissions, and grant consent before importing certificates. Delegated-only configurations can use an appropriately authorized tenant administrator when consent is required.

After consent, pass the setup object directly to authentication. When `-CreateClientSecret` was requested, authentication uses its one-time `SecureString` secret. Otherwise, it starts device-code authentication:

```powershell
Set-IntuneAuthenticationToken -Setup $setup
```

For an existing registration, use its client ID. `-ValidateOnly` is read-only and reports missing permissions, public-client configuration, or service principal creation without changing the tenant:

```powershell
Initialize-IntunePfxImportApplication `
    -ExistingApplicationId '<application-client-id>' `
    -AuthenticationMode Both `
    -ValidateOnly
```

For GCC High, use the sovereign cloud endpoints in both onboarding and authentication:

```powershell
$setup = Initialize-IntunePfxImportApplication `
    -AuthenticationMode Both `
    -AuthUri 'login.microsoftonline.us' `
    -GraphUri 'https://graph.microsoft.us' `
    -ConnectGraph

Set-IntuneAuthenticationToken -Setup $setup
```

Imported PFX certificates require the Certificate Connector to access the private key that protects imported PFX passwords. See [Configure and use imported PKCS certificates with Intune](https://learn.microsoft.com/intune/device-configuration/certificates/imported-pfx-profiles).

## Install and authenticate

Import the script module directly:

```powershell
Import-Module .\PFXImportPS\IntunePfxImport.psd1
```

All app and cloud settings are command-line parameters. Commercial-cloud defaults are safe for `AuthUri`, `GraphUri`, `SchemaVersion`, and `RedirectUri`. Prefer `-Setup $setup`; use the explicit parameters below for an existing registration or unattended automation that does not use the onboarding function.

```powershell
$clientSecret = Read-Host 'Application client secret' -AsSecureString
Set-IntuneAuthenticationToken `
    -ClientId '<application-client-id>' `
    -TenantId '<tenant-id>' `
    -ClientSecret $clientSecret
```

For delegated device-code authentication, omit `ClientSecret`. `AdminUserName` is accepted as a login hint. Username/password authentication remains available only for existing ROPC integrations and is discouraged.

```powershell
Set-IntuneAuthenticationToken -ClientId '<application-client-id>' -TenantId '<tenant-id>' -AdminUserName 'admin@contoso.com'
```

Government cloud uses its own authority and Graph host:

```powershell
Set-IntuneAuthenticationToken `
    -ClientId '<application-client-id>' `
    -TenantId '<tenant-id>' `
    -ClientSecret $clientSecret `
    -AuthUri 'login.microsoftonline.us' `
    -GraphUri 'https://graph.microsoft.us'
```

Run `Remove-IntuneAuthenticationToken` when finished. The auth context is session-only.

## Local CNG key operations

These state-changing commands support `-WhatIf` and `-Confirm`.
Create the machine key once on the computer that performs password encryption, from an elevated session. `New-IntuneUserPfxCertificate` does not create a missing key implicitly.

```powershell
Add-IntuneKspKey `
    -ProviderName 'Microsoft Software Key Storage Provider' `
    -KeyName 'PfxImportKey'

Export-IntunePublicKey `
    -ProviderName 'Microsoft Software Key Storage Provider' `
    -KeyName 'PfxImportKey' `
    -FilePath .\PfxImportKey.pem `
    -FileFormat Pem
```

`Export-IntunePrivateKey` and `Import-IntunePrivateKey` support connector migration using the historical `RSAFULLPRIVATEBLOB` format. Treat exported private-key files as secrets.

## Create and import a PFX record

The module loads PFX data with `EphemeralKeySet`; it does not write the PFX private key to a certificate store. It detects the certificate public-key algorithm and writes `rsa`, `ecc`, or `unknown` in `keyAlgorithm`. The encryption key remains RSA because it protects the PFX password, not the PFX private key.

PFX passwords must contain only ASCII characters. The Intune Certificate Connector decodes the decrypted password as ASCII, so the module rejects non-ASCII passwords instead of silently changing them.

`UPN` is optional when the PFX contains a UPN or email name. Supply `-UPN` only when the certificate does not encode the target Intune user.

The authenticated account is the operator and is not assumed to be the certificate recipient.

```powershell
$pfxPassword = Read-Host 'PFX password' -AsSecureString
$record = New-IntuneUserPfxCertificate `
    -PathToPfxFile .\user.pfx `
    -PfxPassword $pfxPassword `
    -ProviderName 'Microsoft Software Key Storage Provider' `
    -KeyName 'PfxImportKey' `
    -IntendedPurpose smimeEncryption `
    -PaddingScheme OaepSha512

Import-IntuneUserPfxCertificate -CertificateList $record
```

For encryption away from the connector, use an exported CNG blob or PEM public key:

```powershell
$record = New-IntuneUserPfxCertificate `
    -PathToPfxFile .\user.pfx `
    -PfxPassword $pfxPassword `
    -KeyFilePath .\PfxImportKey.pem
```

Use `Get-IntuneUserPfxCertificate`, `Get-IntuneUserId`, `Import-IntuneUserPfxCertificate -IsUpdate`, and `Remove-IntuneUserPfxCertificate` for Graph CRUD.

Relative input and output paths such as `.\user.pfx` and `.\PfxImportKey.pem` resolve from the caller's current PowerShell location.

## Migration from 3.0

- Replace the built DLL import with `Import-Module .\PFXImportPS\IntunePfxImport.psd1`.
- Remove all `PrivateData` values from `IntunePfxImport.psd1`. Use `Set-IntuneAuthenticationToken -Setup $setup`, or pass `ClientId`, `TenantId`, and `ClientSecret` explicitly for an existing automation flow.
- Replace manual Entra application setup with `Initialize-IntunePfxImportApplication`, grant consent through its `AdminConsentUri`, then pass the result directly to `Set-IntuneAuthenticationToken -Setup`.
- Pass sovereign-cloud `AuthUri` and `GraphUri` to `Set-IntuneAuthenticationToken`; do not edit or copy a government-cloud manifest.
- Existing public command names, CNG blob formats, PEM public-key support, Graph resource paths, `-IsUpdate`, padding values, and PFX object fields remain available.
- `Set-IntuneAuthenticationToken` caches only session state. Reauthenticate after a user token expires.

## Tests

Run isolated Pester tests without administrator access, a certificate store, network access, or credentials:

```powershell
Invoke-Pester .\Tests\IntunePfxImport.Tests.ps1 -Output Detailed
```
