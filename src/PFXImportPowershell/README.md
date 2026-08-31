# Intune PFX Import PowerShell module

Version 3.0 ports the shipped Version 2 compiled cmdlets to a PowerShell script
module. Existing command names and common invocation patterns remain available.
Version 3 adds PowerShell 7 support, ECC certificate handling, command-line
configuration, and Entra application onboarding.

`EncryptionUtilities` remains only for `OnPremValidation`; it is not a module
dependency.

## Requirements

- Windows PowerShell 5.1 with .NET Framework 4.7.2, or PowerShell 7 on Windows.
- An Entra application with `DeviceManagementConfiguration.ReadWrite.All`,
  `User.Read.All`, and, for delegated authentication, `User.Read`.
- Admin consent for the required Graph permissions.
- A Windows CNG provider and machine key accessible to the Intune Certificate
  Connector. `Microsoft Software Key Storage Provider` is suitable for testing.

CNG key operations are Windows-only. Run key creation and import from an
elevated PowerShell session.

## Install

The PowerShell module does not need to be built. Download or clone the
repository, then import the module manifest directly:

```powershell
Import-Module .\PFXImportPS\IntunePfxImport.psd1
```

The retained compiled projects are only used to test an on-premises connector's
ability to access the encryption key. Most administrators do not need them. See
[On-premises validation](OnPremValidation/README.md) if you need to build and
run those optional tools.

## Quick start

Choose either automated or manual Entra application configuration. Both paths
use the same Version 3 cmdlets for authentication and PFX import.

### Option 1: Configure the Entra application with the cmdlet

This is the quickest path for a new tenant-specific application:

```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications `
    -Scope CurrentUser

Import-Module .\PFXImportPS\IntunePfxImport.psd1

$setup = Initialize-IntunePfxImportApplication `
    -DisplayName 'Intune PFX Import' `
    -AuthenticationMode PublicClient `
    -ConnectGraph

Start-Process $setup.AdminConsentUri
# An authorized tenant administrator must review and grant admin consent.

Set-IntuneAuthenticationToken -Setup $setup
```

`Initialize-IntunePfxImportApplication`:

- Connects to Microsoft Graph with `Application.ReadWrite.All` and
  `Application.Read.All` when `-ConnectGraph` is specified and no Graph SDK
  connection exists.
- Reuses one exact display-name match or creates a single-tenant application.
- Configures the required delegated Microsoft Graph permissions, public-client
  flow, and native-client redirect URI.
- Creates the application's service principal when it does not exist.
- Returns a setup object containing the client ID, tenant ID, cloud endpoints,
  authentication settings, and admin-consent URL.

The cmdlet does not grant admin consent. An authorized administrator must open
`$setup.AdminConsentUri` and approve the requested permissions. `$setup` can
then be passed directly to `Set-IntuneAuthenticationToken`; do not unpack it
into separate arguments.

Use `-ExistingApplicationId` to update a specific registration,
`-ValidateOnly` to report required changes without modifying the tenant, or
`-AuthenticationMode ClientSecret -CreateClientSecret` for unattended
authentication. A newly created secret is returned once in
`$setup.ClientSecret`.

### Option 2: Configure the Entra application manually

Admins who prefer portal configuration can keep the Version 2 setup workflow:

1. Follow [Quickstart: Register an application with the Microsoft identity
   platform](https://learn.microsoft.com/entra/identity-platform/quickstart-register-app)
   and create a single-tenant application.
2. For interactive device-code authentication, add the **Mobile and desktop
   applications** platform, use
   `https://login.microsoftonline.com/common/oauth2/nativeclient` as the
   redirect URI, and enable public-client flows.
3. Add delegated Microsoft Graph permissions
   `DeviceManagementConfiguration.ReadWrite.All`, `User.Read.All`, and
   `User.Read`.
4. Grant tenant-wide admin consent.
5. Record the application (client) ID and directory (tenant) ID, then
   authenticate:

```powershell
Import-Module .\PFXImportPS\IntunePfxImport.psd1

Set-IntuneAuthenticationToken `
    -ClientId '<application-client-id>' `
    -TenantId '<tenant-id>' `
    -AdminUserName 'admin@contoso.com'
```

For unattended authentication, configure
`DeviceManagementConfiguration.ReadWrite.All` and `User.Read.All` as
**application** permissions, grant admin consent, and create a client secret.
Pass the secret at runtime instead of storing it in the module manifest:

```powershell
$clientSecret = Read-Host 'Application client secret' -AsSecureString
Set-IntuneAuthenticationToken `
    -ClientId '<application-client-id>' `
    -TenantId '<tenant-id>' `
    -ClientSecret $clientSecret
```

### Create and import the PFX record

After authenticating with either option, create the connector encryption key,
prepare the Graph record, import it, and verify it:

```powershell
Add-IntuneKspKey `
    -ProviderName 'Microsoft Software Key Storage Provider' `
    -KeyName 'PfxImportKey'

$pfxPassword = Read-Host 'PFX password' -AsSecureString
$record = New-IntuneUserPfxCertificate `
    -PathToPfxFile .\user.pfx `
    -PfxPassword $pfxPassword `
    -UPN user@contoso.com `
    -ProviderName 'Microsoft Software Key Storage Provider' `
    -KeyName 'PfxImportKey' `
    -IntendedPurpose smimeEncryption

Import-IntuneUserPfxCertificate -CertificateList $record
Get-IntuneUserPfxCertificate -UserList user@contoso.com
```

`Add-IntuneKspKey` creates the machine CNG key used by the Intune Certificate
Connector to decrypt the PFX password. `New-IntuneUserPfxCertificate` reads the
PFX without installing it, encrypts its password with that CNG key, and creates
the local Graph record. `Import-IntuneUserPfxCertificate` sends the record to
Intune. `Get-IntuneUserPfxCertificate` reads the persisted record back.

Run `Remove-IntuneAuthenticationToken` when finished.

## Operator identity and target UPN

These are different identities:

- **Operator identity** -- the account or application authenticating to Graph.
- **Target UPN** -- the existing Entra user that receives the imported
  certificate record.

`-UPN` does not control authentication. It must identify a user in the tenant
where the operator authenticated. It can be omitted when the PFX certificate
contains a UPN or email Subject Alternative Name.

Validate the target before import:

```powershell
Get-IntuneUserId -UPN user@contoso.com
```

## Entra application onboarding

`Initialize-IntunePfxImportApplication` creates or validates the tenant-specific
application through `Microsoft.Graph.Authentication` and
`Microsoft.Graph.Applications`. The operator needs `Application.ReadWrite.All`
and `Application.Read.All`.

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser

$setup = Initialize-IntunePfxImportApplication `
    -DisplayName 'Intune PFX Import' `
    -AuthenticationMode Both `
    -CreateClientSecret `
    -ConnectGraph
```

An exact display-name match is reused. Multiple matches cause an error. Use
`-ExistingApplicationId` to select an application deterministically.

For application permissions, a Privileged Role Administrator or Global
Administrator must open `$setup.AdminConsentUri`, review the permissions, and
grant tenant-wide consent. The Graph SDK cannot silently grant consent.

`-ValidateOnly` reports missing permissions, public-client configuration, and
service-principal creation without changing the tenant:

```powershell
Initialize-IntunePfxImportApplication `
    -ExistingApplicationId '<application-client-id>' `
    -AuthenticationMode Both `
    -ValidateOnly
```

For GCC High, use the matching endpoints during onboarding and authentication:

```powershell
$setup = Initialize-IntunePfxImportApplication `
    -AuthenticationMode Both `
    -AuthUri 'login.microsoftonline.us' `
    -GraphUri 'https://graph.microsoft.us' `
    -ConnectGraph

Set-IntuneAuthenticationToken -Setup $setup
```

## Authentication options

Prefer a setup object. For an existing unattended application:

```powershell
$clientSecret = Read-Host 'Application client secret' -AsSecureString
Set-IntuneAuthenticationToken `
    -ClientId '<application-client-id>' `
    -TenantId '<tenant-id>' `
    -ClientSecret $clientSecret
```

For device-code authentication, omit `ClientSecret`. `AdminUserName` is an
operator login hint. Username/password authentication remains available for
existing ROPC integrations but is discouraged.

```powershell
Set-IntuneAuthenticationToken `
    -ClientId '<application-client-id>' `
    -TenantId '<tenant-id>' `
    -AdminUserName admin@contoso.com
```

Version 2 manifest `PrivateData` keys remain as a migration fallback:
`ClientId`, `ClientSecret`, `TenantId`, `AuthURI`, `GraphURI`,
`SchemaVersion`, and `RedirectURI`. Existing scripts can still call
`Set-IntuneAuthenticationToken -AdminUserName ...` or, when all application
credentials are configured, `Set-IntuneAuthenticationToken` with no arguments.
Do not store new secrets in the manifest--use `-Setup` or command-line
`SecureString` input.

Run `Remove-IntuneAuthenticationToken` when finished. Authentication state is
kept only in the current module session.

## CNG encryption key

The CNG key does not replace the private key inside the imported PFX. It encrypts
the PFX password so the Certificate Connector can decrypt and install the PFX.
Create the machine key once on the encryption computer:

```powershell
Add-IntuneKspKey `
    -ProviderName 'Microsoft Software Key Storage Provider' `
    -KeyName 'PfxImportKey'
```

The software-provider ACL grants built-in Administrators full control and
Server Operators and Local System read access. Confirm that the connector
service identity can open the selected provider and key.

Provider and key values supplied to `New-IntuneUserPfxCertificate` are remembered
for later calls in the same module session, matching Version 2 behavior.

For encryption on a different computer, export the public key:

```powershell
Export-IntunePublicKey `
    -ProviderName 'Microsoft Software Key Storage Provider' `
    -KeyName 'PfxImportKey' `
    -FilePath .\PfxImportKey.pem `
    -FileFormat Pem

$record = New-IntuneUserPfxCertificate `
    -PathToPfxFile .\user.pfx `
    -PfxPassword $pfxPassword `
    -KeyFilePath .\PfxImportKey.pem
```

PEM content is detected regardless of file extension. Public CNG blobs use
`RSAPUBLICBLOB`. Private-key migration retains the Version 2
`RSAFULLPRIVATEBLOB` format. Treat exported private-key files as secrets.

## Create, import, verify, and remove

The module loads PFX data with `EphemeralKeySet`; it does not install the PFX
private key into a certificate store. PFX passwords must contain only ASCII
characters because the Certificate Connector decodes the decrypted password as
ASCII.

The local object reports `KeyAlgorithm` as `rsa`, `ecc`, or `unknown`.
`keyAlgorithm` is not part of the Graph `userPFXCertificate` schema and is not
sent during import.

Version 2 purpose numbers remain accepted:

| Value | Purpose |
| --- | --- |
| `0` | `unassigned` |
| `1` | `smimeEncryption` |
| `2` | `smimeSigning` |
| `4` | `vpn` |
| `8` | `wifi` |

`-PaddingScheme None` remains a compatibility alias for `OaepSha512`.

Verify an import by UPN and thumbprint:

```powershell
$persisted = Get-IntuneUserPfxCertificate -UserThumbprintList @{
    User = $record.UserPrincipalName
    Thumbprint = $record.Thumbprint
}
```

Graph intentionally redacts sensitive fields on read-back:

- `EncryptedPfxBlob` appears as the Base64 value `AA==`.
- `EncryptedPfxPassword` is empty.

Those values do not mean the import failed. Verify the UPN, thumbprint, intended
purpose, and dates instead.

Removal accepts either the Version 2 directory user ID or a UPN in each
`UserThumbprintList.User` value:

```powershell
Remove-IntuneUserPfxCertificate -UserThumbprintList @{
    User = $record.UserPrincipalName
    Thumbprint = $record.Thumbprint
}
```

Import and removal continue to later records after an item failure. Use
`-ErrorAction Stop` when the caller needs fail-fast behavior. State-changing
commands support `-WhatIf` and `-Confirm`.

Relative paths resolve from the caller's current PowerShell location.

## Version 2 compatibility

Version 3 preserves:

- All 12 shipped Version 2 command names.
- Existing positional indexes and pipeline input.
- Existing parameter-set names for list and removal operations.
- CNG `RSAPUBLICBLOB`, PEM, and `RSAFULLPRIVATEBLOB` formats.
- Version 2 intended-purpose numbers and `PaddingScheme None`.
- Provider/key carry-forward within a module session.
- Manifest-based authentication as a deprecated migration fallback.
- PascalCase PFX object properties and the
  `Microsoft.Management.Services.Api.UserPFXCertificate` PowerShell type name.
- Graph paths, update behavior, and per-record batch continuation.

The old compiled CLR classes and enums are not loaded. Scripts should use
properties rather than static CLR casts. `Initialize-IntunePfxImportApplication`,
setup-object authentication, UPN inference, ECC metadata, safer path handling,
bounded retries, and `WhatIf` support are Version 3 extensions.

## Non-production E2E sample

`Examples\Test-IntunePfxImportE2E.ps1` demonstrates the full workflow against a
live tenant.

```powershell
.\Examples\Test-IntunePfxImportE2E.ps1 -TargetUpn user@contoso.com
```

**Do not use this sample as production automation.** It requires elevated
PowerShell 7, can install Graph modules, creates or reuses an Entra application,
creates a machine key and temporary ECC PFX file, and writes an Intune PFX
record. By default it removes the key, PFX file, and Intune record. The Entra
application remains for reuse. `-KeepArtifacts` retains the machine key and
Intune record, but the temporary PFX file is always deleted. It also retains the
authentication context for inspection.

## Tests

```powershell
Invoke-Pester .\Tests\IntunePfxImport.Tests.ps1 -Output Detailed
```
