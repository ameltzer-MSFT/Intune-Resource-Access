# PFXImport Powershell Project

This project consists of helper Powershell Commandlets for importing PFX certificates to Microsoft Intune. Prior to running these scripts you will need to create the PFX files to import. Further documentation of the feature can be found [here](https://docs.microsoft.com/en-us/intune/certificates-s-mime-encryption-sign).

These scripts provide a baseline for the actions that can take place to import your PFX Certificates to Intune. They can be modified and adapted to fit your workflow. Most of the cmdlets are wrappers of Intune Graph calls.

## What's New?

### Version 3.0

- Raised the build and runtime baseline to .NET Framework 4.7.2.
- Modernized the direct package dependencies, including MSAL, Newtonsoft.Json, Moq, and Castle.Core.
- Added ECC PFX support with `ecc` public-key algorithm metadata and ephemeral PFX private-key loading.
- Replaced deprecated MSAL request-authority overrides with tenant-specific requests. AuthURI still selects the commercial or sovereign cloud host.
- Marked username/password (ROPC) authentication as deprecated. Interactive user authentication and application client-secret authentication remain supported.

### Version 2.0

- Breaking changes:
  - The global Intune app registration has been deprecated for use with PFXImport. The client ID for the Global Intune application has been removed from these scripts. A tenant-specific app registration _must be created_ and its client ID added to your IntunePfxImport.psd1 file.
  - The previously deprecated Get-IntuneAuthenticationToken command has been removed.  Use Set-IntuneAuthenticationToken instead.  The associated AuthenticationResult parameter has also been removed from the other various commands.
  - Changed the default redirect uri to <https://login.microsoftonline.com/common/oauth2/nativeclient> as recommended by Microsoft Azure.
- Added the ability to authenticate using a client secret instead of user authentication. This is configured in the app registration and IntunePfxImport.psd1 file.
- Switched the underlying authentication library from ADAL (which will soon be unsupported) to MSAL.

### Version 1.1

- Added functionality to make private keys exportable, a cmdlet to export the key, and a cmdlet to import a key.
  - Allows migrating connectors when using the Microsoft Software Key Storage Provider.
  - Serious security considerations needs to be taken when transferring keys between machines.
- Deprecated the Get-IntuneAuthenticationToken cmdlet in favore of the new Set-IntuneAuthenticationToken to store the authentication token so that it isn't required as a parameter on every call that interacts with Intune.
  - Calling Remove-IntuneAuthenticationToken or closing the session is recommended when calls to Intune are complete.

# Configure a Microsoft Azure App Registration

An app registration must be configured for your tenant.  Create the app registration in the Microsoft Azure portal.

[Quickstart: Register an application with the Microsoft identity platform](https://docs.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app)

Set the redirect uri for the Public client/native (mobile & desktop) platform to <https://login.microsoftonline.com/common/oauth2/nativeclient>

- The redirect uri used by scripts can optionally be modified by adding the "RedirectURI" setting to the PrivateData section of your IntunePfxImport.psd1 file

The following Microsoft Graph API permissions are required:

- DeviceManagementConfiguration.ReadWrite.All
- User.Read.All

Additionally required when using user-based authentication:

- User.Read

Add these permissions as delegated permissions when using user-based authentication or application permissions when using an application client secret.  Grant admin consent for the permissions.

If using user-based authentication in a non-interactive session (by specifying the password on the PowerShell command line), you must enable the “Allow public client flows” setting on the app registration "Authentication" page.

If using an application client secret for authentication, create the secret under "Certificates & secrets".  Save the secret before leaving the page, as you will not be able to view it again later.  The secret value will be provided in the IntunePfxImport.psd1 file (see details below).

# Building the Commandlets

## Prerequisite

Visual Studio 2019 (or above) with the .NET Framework 4.7.2 Developer Pack.

## Building

1. Load .\PFXImportPS.sln in Visual Studio
2. Select the appropriate build configuration (Debug or Release)
3. Build solution

## Dependency baseline

The solution uses legacy `packages.config` manifests. The direct package baseline is:

| Package | Version |
| --- | --- |
| Castle.Core | 5.2.1 |
| Microsoft.Identity.Client | 4.88.0 |
| Moq | 4.20.72 |
| Newtonsoft.Json | 13.0.4 |
| System.Runtime.CompilerServices.Unsafe | 6.1.2 |
| System.Threading.Tasks.Extensions | 4.6.3 |
| System.ValueTuple | 4.6.2 |

`System.Management.Automation.dll` remains pinned to the Windows PowerShell-compatible reference used by the cmdlets.

# Example Powershell Usage

## Prerequisite

1. Update the IntunePfxImport.psd1 file with details about your app registration. This usually is found in the "bin\debug" or "bin\release" directory.

- Set the ClientId setting to the "application (client) Id" from the app registration "Overview" page.
- If using an application client secret:
  - Create the secret in your app registration and specify it in the ClientSecret setting in IntunePfxImport.psd1.  Be sure to keep this file secure.
  - The TenantId setting is also required when using a client secret.  This value can be found on the app registration "Overview" page.
  - AuthURI selects the Microsoft Entra cloud authority host. Keep the default `login.microsoftonline.com` for commercial cloud, or use the government-cloud module configuration for `login.microsoftonline.us`.

1. Import the built powershell module.

```powershell
Import-Module .\IntunePfxImport.psd1
```

## Create initial Key Example

1. Setup Key -- Convenience method for creating a key. Key's may be created with other tools. If you don't have a dedicated provider, you can use "Microsoft Software Key Storage Provider". Only include the MakeExportable switch if you must have the ability to move the key to another machine.

```powershell
Add-IntuneKspKey "<ProviderName>" "<KeyName>" {-MakeExportable}
```

## Export the public key to a file

1. Export the public key. Used to encrypt in an independent location from where the private key is accessed. Set "Set up userPFXCertificate object (scenario: encrypting password with the public key that has been exported to a file)" below.

```powershell
Export-IntunePublicKey -ProviderName "<ProviderName>" -KeyName "<KeyName>" -FilePath "<File path to write to>"
```

## Export the private key to a file

1. Export the private key. For use when migrating connector and moving keys between machines.

```powershell
Export-IntunePublicKey -ProviderName "<ProviderName>" -KeyName "<KeyName>" -FilePath "<File path to write to>" {-MakeExportable}
```

## Import the private key from a file

1. Import the private key. For use when migrating connector and moving keys between machines.

```powershell
Import-IntunePublicKey -ProviderName "<ProviderName>" -KeyName "<KeyName>" -FilePath "<File path to write to>"
```

## Authenticate to Intune

### User Authentication with interactive login

1. Authenticate as the account administrator (using the admin UPN) to Intune. Specify the AdminUserName on the command line, but not the AdminPassword.  An interactive login dialog will appear.

```powershell
Set-IntuneAuthenticationToken -AdminUserName "<Admin-UPN>"
```

1. Make sure the call Remove-IntuneAuthenticationToken to clear the token cache when all interation with Intune is complete.  Close the PowerShell session to remove credentials cached by the interactive browser.

### User authentication with non-interactive login (deprecated)

This username/password (ROPC) flow is deprecated by Microsoft Entra. Prefer interactive login or application client-secret authentication for new integrations. Existing scripts can continue using this option while a replacement non-interactive flow is designed.

Prerequisite: to use this option, enable “Allow public client flows” setting on the app registration "Authentication" page.

1. Optionally, create a secure string representing the account administrator password.

```powershell
$secureAdminPassword = ConvertTo-SecureString -String "<admin password>" -AsPlainText -Force
```

1. Authenticate as the account administrator (using the admin UPN) to Intune.  Provide both the user name and the password on the command line.

```powershell
Set-IntuneAuthenticationToken -AdminUserName "<Admin-UPN>" [-AdminPassword $secureAdminPassword]
```

1. Make sure the call Remove-IntuneAuthenticationToken to clear the token cache when all interation with Intune is complete.

### Application client secret authentication

Prerequisite: create the client secret in the app registration and configure the IntunePfxImport.psd1 file.

1. Set-IntuneAuthenticationToken will use configured client secret settings if it is called with no parameters

```powershell
Set-IntuneAuthenticationToken
```

## Set up userPFXCertificate object (scenario: encrypting password from a location that has acccess to the private key in the key store)

1. Setup Secure File Password string.

```powershell
$SecureFilePassword = ConvertTo-SecureString -String "<PFXPassword>" -AsPlainText -Force
```

1. (Optional) Format a Base64 encoded certificate.

```powershell
$Base64Certificate =ConvertTo-IntuneBase64EncodedPfxCertificate -CertificatePath "<FullPathPFXToCert>"
```

1. Create a new UserPfxCertificate record.

```powershell
$userPFXObject = New-IntuneUserPfxCertificate -Base64EncodedPFX $Base64Certificate -PfxPassword $SecureFilePassword -UPN "<UserUPN>" -ProviderName "<ProviderName>" -KeyName "<KeyName>" -IntendedPurpose "<IntendedPurpose>" {-PaddingScheme "<PaddingScheme>"}
```

or

```powershell
$userPFXObject = New-IntuneUserPfxCertificate -PathToPfxFile "<FullPathPFXToCert>" -PfxPassword $SecureFilePassword -UPN "<UserUPN>" -ProviderName "<ProviderName>" -KeyName "<KeyName>" -IntendedPurpose "<IntendedPurpose>" {-PaddingScheme "<PaddingScheme>"}
```

### ECC PFX files

`New-IntuneUserPfxCertificate` supports ECC PFX files, including P-384 certificates created with:

```powershell
$certificate = New-SelfSignedCertificate -Subject "CN=ECC PFX" -KeyAlgorithm ECDSA_P384 -CertStoreLocation "Cert:\CurrentUser\My"
Export-PfxCertificate -Cert $certificate -FilePath "<FullPathPFXToCert>" -Password $SecureFilePassword
```

The cmdlet imports the PFX with an ephemeral key set and detects the certificate public-key algorithm as `rsa`, `ecc`, or `unknown` before creating the `userPFXCertificate` object. `Add-IntuneKspKey` remains an RSA key-generation helper for encrypting the imported PFX password; it does not create the certificate's ECC private key.

## Set up userPFXCertificate object (scenario: encrypting password with the public key that has been exported to a file)

1. Setup Secure File Password string.

```powershell
$SecureFilePassword = ConvertTo-SecureString -String "<PFXPassword>" -AsPlainText -Force
```

1. (Optional) Format a Base64 encoded certificate.

```powershell
$Base64Certificate =ConvertTo-IntuneBase64EncodedPfxCertificate -CertificatePath "<FullPathPFXToCert>"
```

1. Create a new UserPfxCertificate record.

```powershell
$userPFXObject = New-IntuneUserPfxCertificate -Base64EncodedPFX $Base64Certificate -PfxPassword $SecureFilePassword -UPN "<UserUPN>" -ProviderName "<ProviderName>" -KeyName "<KeyName>" -IntendedPurpose "<IntendedPurpose>" -KeyFilePath "<File path to public key file>"
```

or

```powershell
$userPFXObject = New-IntuneUserPfxCertificate -PathToPfxFile "<FullPathPFXToCert>" -PfxPassword $SecureFilePassword -UPN "<UserUPN>" -ProviderName "<ProviderName>" -KeyName "<KeyName>" -IntendedPurpose "<IntendedPurpose>" -KeyFilePath "<File path to public key file>"
```

## Import Example

1. Import User PFX

```powershell
Import-IntuneUserPfxCertificate -CertificateList $userPFXObject
```

## Get PFX Certificate Example

1. Get-PfxCertificates (Specific records)

```powershell
Get-IntuneUserPfxCertificate -UserThumbprintList <UserThumbprintObjs>
```

1. Get-PfxCertificates (Specific users)

```powershell
Get-IntuneUserPfxCertificate -UserList "<UserUPN>"
```

1. Get-PfxCertificates (All records)

```powershell
Get-IntuneUserPfxCertificate
```

## Remove PFX Certificate Example

1. Remove-PfxCertificates (Specific records)

```powershell
Remove-IntuneUserPfxCertificate -UserThumbprintList <UserThumbprintObjs>
```

1. Remove-PfxCertificates (Specific users)

```powershell
Remove-IntuneUserPfxCertificate -UserList "<UserUPN>"
```

## Remove Authentication Token from session (logout)

To unselect the authentication token:

```powershell
Remove-IntuneAuthenticationToken
```

Note: To clear all caches used internally by MSAL APIs, also close the PowerShell session.

# Graph Usage

See [UserPFXCertificate Graph resource type](https://docs.microsoft.com/en-us/graph/api/resources/intune-raimportcerts-userpfxcertificate?view=graph-rest-beta)

## GET

A specific record

```powershell
https://graph.microsoft.com/beta/deviceManagement/userPfxCertificates('{Userid}-{Thumbprint}')
```

A specific User

```powershell
https://graph.microsoft.com/beta/deviceManagement/userPfxCertificates/?$filter=tolower(userPrincipalName) eq '{lowercase UPN}'
```

All records

```powershell
https://graph.microsoft.com/beta/deviceManagement/userPfxCertificates
```

## POST

 <https://graph.microsoft.com/beta/deviceManagement/userPfxCertificates>

with an example payload:

```json
{
"id": "",
"thumbprint": "f6f5f8f6-f8f6-f6f5-f6f8-f5f6f6f8f5f6",
"intendedPurpose": "smimeEncryption",
"userPrincipalName": "<User1@contoso.onmicrosoft.com>",
"startDateTime": "2016-12-31T23:58:46.7156189-07:00",
"expirationDateTime": "2016-12-31T23:57:57.2481234-07:00",
"providerName": "Microsoft Software Key Storage Provider",
"keyName": "KeyNameValue",
"paddingScheme": "oaepSha512",
"encryptedPfxBlob": "MIIaHR0cHM6Ly93d3cuYmFzZTY0ZW5jb2RlLm.......",
"encryptedPfxPassword": ".......0dHBzOi8vd3d3LmJhc2U2NGVuY29kZS5vcm==",
"createdDateTime": "2017-01-01T00:02:43.5775965-07:00",
"lastModifiedDateTime": "2017-01-01T00:00:35.1329464-07:0"
}
```

## PATCH

 <https://graph.microsoft.com/beta/deviceManagement/userPfxCertificates('{UserId}-{Thumbprint}>')

For payload, see above example.

## DELETE

 <https://graph.microsoft.com/beta/deviceManagement/userPfxCertificates('{UserId}-{Thumbprint}>')

# Notes

- While encryptedPfxBlob and encryptedPfxPassword must be provided when a UserPFXCertificate record is imported, those values will be returned empty in any get call.

 A returned json object will be similar to this:

```json
{
 "id": "5ffff976dffffe49affff8978fffff25-0ffff8962ffffdea9ffff8e83ffff1d83ffff6ae",
 "thumbprint": "0ffff8962ffffdea9ffff8e83ffff1d83ffff6ae",
 "intendedPurpose": "smimeEncryption",
 "userPrincipalName": "<User1@contoso.onmicrosoft.com>",
 "startDateTime": "2016-12-31T23:58:46.7156189-07:00",
 "expirationDateTime": "2016-12-31T23:57:57.2481234-07:00",
 "providerName": "Microsoft Software Key Storage Provider",
 "keyName": "KeyNameValue",
 "paddingScheme": "oaepSha512",
 "encryptedPfxBlob": "AA==",
 "encryptedPfxPassword": "",
 "createdDateTime": "2017-01-01T00:02:43.5775965-07:00",
 "lastModifiedDateTime": "2017-01-01T00:00:35.1329464-07:0"
}
```

- The public key used for encryption's equivalent private key must be accessible to the account that is running the "PFX Certificate Connector for Microsoft Intune" service for decryption to work. This is normally the "NT AUTHORITY\System" account. See the [OnPremValidation project](OnPremValidation) for testing access.

# Other Useful graph examples

## Lookup up user id from UPN

 GET
 <https://graph.microsoft.com/beta/users?$filter=userPrincipalName> eq '{UPN}'

The user id is found in the id value of the returned object.
