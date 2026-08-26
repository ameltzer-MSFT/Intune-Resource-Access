Set-StrictMode -Version Latest

$script:AuthContext = $null
$script:CommercialAuthUri = 'login.microsoftonline.com'
$script:CommercialGraphUri = 'https://graph.microsoft.com'
$script:DefaultRedirectUri = 'https://login.microsoftonline.com/common/oauth2/nativeclient'

function ConvertTo-PlainText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function ConvertTo-PasswordBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)

    $plainText = ConvertTo-PlainText -SecureString $SecureString
    try {
        if ($plainText -match '[^\x00-\x7f]') {
            throw [ArgumentException]::new('PFX passwords must contain only ASCII characters because the Intune Certificate Connector decodes the decrypted password as ASCII.')
        }
        Write-Output -NoEnumerate ([Text.Encoding]::ASCII.GetBytes($plainText))
    }
    finally {
        $plainText = $null
    }
}

function Get-IntuneAuthorityUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AuthUri,
        [AllowEmptyString()][string]$TenantId
    )

    $hostName = $AuthUri.Trim().TrimEnd('/')
    if ($hostName -match '^https?://') {
        $hostName = ([uri]$hostName).Authority
    }
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        throw [ArgumentException]::new('AuthUri cannot be empty.')
    }
    $tenant = if ([string]::IsNullOrWhiteSpace($TenantId)) { 'organizations' } else { $TenantId }
    return "https://$hostName/$tenant"
}

function Get-IntuneAccessToken {
    [CmdletBinding()]
    param()

    if ($null -eq $script:AuthContext) {
        throw [InvalidOperationException]::new('No token cached. First call Set-IntuneAuthenticationToken.')
    }

    if ($script:AuthContext.AccessToken -and $script:AuthContext.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) {
        return $script:AuthContext.AccessToken
    }

    if ($script:AuthContext.AuthenticationType -ne 'ClientSecret') {
        throw [InvalidOperationException]::new('The cached user token has expired. Call Set-IntuneAuthenticationToken again.')
    }

    $secret = ConvertTo-PlainText -SecureString $script:AuthContext.ClientSecret
    try {
        $response = Invoke-RestMethod -Method Post -Uri "$($script:AuthContext.Authority)/oauth2/v2.0/token" -Body @{
            client_id = $script:AuthContext.ClientId
            client_secret = $secret
            scope = "$($script:AuthContext.GraphUri)/.default"
            grant_type = 'client_credentials'
        } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    }
    finally {
        $secret = $null
    }

    if ([string]::IsNullOrWhiteSpace($response.access_token)) {
        throw [Security.Authentication.AuthenticationException]::new('The token endpoint did not return an access token.')
    }

    $script:AuthContext.AccessToken = $response.access_token
    $script:AuthContext.ExpiresOn = [DateTimeOffset]::UtcNow.AddSeconds([int]$response.expires_in)
    return $script:AuthContext.AccessToken
}

function Get-IntuneGraphUri {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($null -eq $script:AuthContext) {
        throw [InvalidOperationException]::new('No authentication context exists. Call Set-IntuneAuthenticationToken first.')
    }

    $absoluteUri = $null
    if ([uri]::TryCreate($Path, [UriKind]::Absolute, [ref]$absoluteUri)) {
        $graphUri = [uri]$script:AuthContext.GraphUri
        if ($absoluteUri.Scheme -ne 'https' -or $absoluteUri.Authority -ne $graphUri.Authority) {
            throw [ArgumentException]::new("Graph continuation URI '$Path' does not match the configured Graph endpoint.")
        }
        return $absoluteUri.AbsoluteUri
    }

    return "$($script:AuthContext.GraphUri.TrimEnd('/'))/$($script:AuthContext.SchemaVersion)/$($Path.TrimStart('/'))"
}

function Get-IntuneRetryDelay {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Exception)

    $response = $Exception.Response
    if ($null -eq $response) {
        return $null
    }

    $statusCode = [int]$response.StatusCode
    if ($statusCode -ne 429 -and $statusCode -lt 500) {
        return $null
    }

    $milliseconds = $null
    $seconds = $null
    if ($response.Headers -is [Net.WebHeaderCollection]) {
        $milliseconds = $response.Headers['x-ms-retry-after-ms']
        $seconds = $response.Headers['Retry-After']
    }
    else {
        [Collections.Generic.IEnumerable[string]]$headerValues = $null
        if ($response.Headers.TryGetValues('x-ms-retry-after-ms', [ref]$headerValues)) {
            $milliseconds = @($headerValues)[0]
        }
        $headerValues = $null
        if ($response.Headers.TryGetValues('Retry-After', [ref]$headerValues)) {
            $seconds = @($headerValues)[0]
        }
    }

    if ($milliseconds) {
        return [Math]::Max(1, [int][Math]::Ceiling(([double]$milliseconds) / 1000))
    }

    $parsedSeconds = 0
    if ($seconds -and [int]::TryParse($seconds, [ref]$parsedSeconds)) {
        return [Math]::Max(1, $parsedSeconds)
    }
    return 5
}

function Invoke-IntuneGraphRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Get', 'Post', 'Patch', 'Delete')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()]$Body
    )

    $uri = Get-IntuneGraphUri -Path $Path
    $accessToken = Get-IntuneAccessToken
    $headers = @{ Authorization = "Bearer $accessToken" }
    $parameters = @{
        Method = $Method
        Uri = $uri
        Headers = $headers
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 8
        $parameters.ContentType = 'application/json'
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return Invoke-RestMethod @parameters
        }
        catch {
            $delay = Get-IntuneRetryDelay -Exception $_.Exception
            if ($null -eq $delay -or $attempt -eq 3) {
                throw
            }
            Write-Warning "Graph request was throttled or unavailable. Retrying in $delay seconds."
            Start-Sleep -Seconds $delay
        }
    }
}

function ConvertTo-IntuneUserPfxBody {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Certificate)

    $body = [ordered]@{}
    foreach ($property in @(
        'id', 'thumbprint', 'keyAlgorithm', 'intendedPurpose', 'userPrincipalName',
        'startDateTime', 'expirationDateTime', 'providerName', 'keyName',
        'paddingScheme', 'encryptedPfxBlob', 'encryptedPfxPassword',
        'createdDateTime', 'lastModifiedDateTime'
    )) {
        $source = $Certificate.PSObject.Properties[$property]
        if ($null -eq $source) {
            $source = $Certificate.PSObject.Properties[($property.Substring(0, 1).ToUpperInvariant() + $property.Substring(1))]
        }
        if ($null -ne $source -and $null -ne $source.Value) {
            $value = $source.Value
            if ($property -eq 'encryptedPfxBlob' -and $value -is [byte[]]) {
                $value = [Convert]::ToBase64String($value)
            }
            elseif ($property -in @('startDateTime', 'expirationDateTime', 'createdDateTime', 'lastModifiedDateTime')) {
                if ($value -is [DateTimeOffset]) {
                    $value = $value.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                }
                elseif ($value -is [DateTime]) {
                    $value = $value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                }
            }
            $body[$property] = $value
        }
    }
    return [pscustomobject]$body
}

function Escape-IntuneODataLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    return $Value.Replace("'", "''")
}

function New-IntuneODataFilterPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Filter
    )

    return "${Path}?`$filter=$([uri]::EscapeDataString($Filter))"
}

function Resolve-IntuneFileSystemPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$MustExist
    )

    if ($MustExist) {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.PSProvider.Name -ne 'FileSystem' -or $item.PSIsContainer) {
            throw [IO.FileNotFoundException]::new("File '$Path' was not found.", $Path)
        }
        return $item.FullName
    }

    $provider = $null
    $drive = $null
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path,
        [ref]$provider,
        [ref]$drive)
    if ($provider.Name -ne 'FileSystem') {
        throw [ArgumentException]::new("Path '$Path' must use the FileSystem provider.")
    }
    return $resolvedPath
}

function Get-IntuneRsaPadding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('OaepSha256', 'OaepSha384', 'OaepSha512')][string]$PaddingScheme)

    switch ($PaddingScheme) {
        'OaepSha256' { return [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256 }
        'OaepSha384' { return [Security.Cryptography.RSAEncryptionPadding]::OaepSHA384 }
        default { return [Security.Cryptography.RSAEncryptionPadding]::OaepSHA512 }
    }
}

function Get-DerElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Data,
        [Parameter(Mandatory)][ref]$Offset
    )

    if ($Offset.Value -ge $Data.Length) {
        throw [IO.InvalidDataException]::new('Unexpected end of DER data.')
    }
    $tag = $Data[$Offset.Value++]
    $lengthByte = $Data[$Offset.Value++]
    $length = 0
    if (($lengthByte -band 0x80) -eq 0) {
        $length = $lengthByte
    }
    else {
        $lengthLength = $lengthByte -band 0x7f
        if ($lengthLength -eq 0 -or $lengthLength -gt 4 -or ($Offset.Value + $lengthLength) -gt $Data.Length) {
            throw [IO.InvalidDataException]::new('Invalid DER length.')
        }
        for ($index = 0; $index -lt $lengthLength; $index++) {
            $length = ($length * 256) + $Data[$Offset.Value++]
        }
    }
    if (($Offset.Value + $length) -gt $Data.Length) {
        throw [IO.InvalidDataException]::new('DER length exceeds input.')
    }
    $value = New-Object byte[] $length
    [Array]::Copy($Data, $Offset.Value, $value, 0, $length)
    $Offset.Value += $length
    return [pscustomobject]@{ Tag = $tag; Value = $value }
}

function ConvertTo-DerLength {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Length)

    if ($Length -lt 128) { return [byte[]]@($Length) }
    $bytes = New-Object Collections.Generic.List[byte]
    $remaining = $Length
    while ($remaining -gt 0) {
        $bytes.Insert(0, [byte]($remaining -band 0xff))
        $remaining = $remaining -shr 8
    }
    $bytes.Insert(0, [byte](0x80 -bor $bytes.Count))
    return $bytes.ToArray()
}

function ConvertTo-DerElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte]$Tag,
        [Parameter(Mandatory)][byte[]]$Value
    )

    $result = New-Object Collections.Generic.List[byte]
    $result.Add($Tag)
    $result.AddRange([byte[]](ConvertTo-DerLength -Length $Value.Length))
    $result.AddRange($Value)
    return $result.ToArray()
}

function ConvertTo-DerUnsignedInteger {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Value)

    $first = 0
    while ($first -lt ($Value.Length - 1) -and $Value[$first] -eq 0) { $first++ }
    $unsigned = $Value[$first..($Value.Length - 1)]
    if (($unsigned[0] -band 0x80) -ne 0) { $unsigned = [byte[]]@(0) + $unsigned }
    return ConvertTo-DerElement -Tag 0x02 -Value $unsigned
}

function ConvertTo-RsaPublicKeyPem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.Cryptography.RSA]$Rsa)

    $parameters = $Rsa.ExportParameters($false)
    $rsaKey = [byte[]](ConvertTo-DerUnsignedInteger -Value $parameters.Modulus) + [byte[]](ConvertTo-DerUnsignedInteger -Value $parameters.Exponent)
    $rsaKey = ConvertTo-DerElement -Tag 0x30 -Value $rsaKey
    $algorithmIdentifier = [byte[]]@(0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00)
    $algorithmIdentifier = ConvertTo-DerElement -Tag 0x30 -Value $algorithmIdentifier
    $bitString = [byte[]]@(0) + $rsaKey
    $subjectPublicKeyInfo = [byte[]]$algorithmIdentifier + [byte[]](ConvertTo-DerElement -Tag 0x03 -Value $bitString)
    $subjectPublicKeyInfo = ConvertTo-DerElement -Tag 0x30 -Value $subjectPublicKeyInfo
    $base64 = [Convert]::ToBase64String($subjectPublicKeyInfo)
    $writer = New-Object IO.StringWriter
    $writer.WriteLine('-----BEGIN PUBLIC KEY-----')
    for ($index = 0; $index -lt $base64.Length; $index += 64) {
        $writer.WriteLine($base64.Substring($index, [Math]::Min(64, $base64.Length - $index)))
    }
    $writer.WriteLine('-----END PUBLIC KEY-----')
    return $writer.ToString()
}

function Get-RsaFromPemFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = Resolve-IntuneFileSystemPath -Path $Path -MustExist
    $pem = [IO.File]::ReadAllText($resolvedPath)
    $base64 = ($pem -replace '-----BEGIN PUBLIC KEY-----', '' -replace '-----END PUBLIC KEY-----', '' -replace '\s', '')
    $der = [Convert]::FromBase64String($base64)
    $offset = 0
    $outer = Get-DerElement -Data $der -Offset ([ref]$offset)
    if ($outer.Tag -ne 0x30) { throw [IO.InvalidDataException]::new('The PEM file does not contain a public-key sequence.') }
    $offset = 0
    $algorithm = Get-DerElement -Data $outer.Value -Offset ([ref]$offset)
    $bitString = Get-DerElement -Data $outer.Value -Offset ([ref]$offset)
    if ($algorithm.Tag -ne 0x30 -or $bitString.Tag -ne 0x03 -or $bitString.Value.Length -lt 2) {
        throw [IO.InvalidDataException]::new('The PEM file is not an RSA SubjectPublicKeyInfo value.')
    }
    $keyBytes = New-Object byte[] ($bitString.Value.Length - 1)
    [Array]::Copy($bitString.Value, 1, $keyBytes, 0, $keyBytes.Length)
    $offset = 0
    $keySequence = Get-DerElement -Data $keyBytes -Offset ([ref]$offset)
    $offset = 0
    $modulus = (Get-DerElement -Data $keySequence.Value -Offset ([ref]$offset)).Value
    $exponent = (Get-DerElement -Data $keySequence.Value -Offset ([ref]$offset)).Value
    if ($modulus[0] -eq 0) { $modulus = $modulus[1..($modulus.Length - 1)] }
    if ($exponent[0] -eq 0) { $exponent = $exponent[1..($exponent.Length - 1)] }
    $parameters = New-Object Security.Cryptography.RSAParameters
    $parameters.Modulus = [byte[]]$modulus
    $parameters.Exponent = [byte[]]$exponent
    $rsa = New-Object Security.Cryptography.RSACng
    $rsa.ImportParameters($parameters)
    return $rsa
}

function Invoke-IntunePasswordEncryption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$PasswordBytes,
        [AllowEmptyString()][string]$ProviderName,
        [AllowEmptyString()][string]$KeyName,
        [AllowEmptyString()][string]$KeyFilePath,
        [Parameter(Mandatory)][string]$PaddingScheme
    )

    $padding = Get-IntuneRsaPadding -PaddingScheme $PaddingScheme
    if (-not [string]::IsNullOrWhiteSpace($KeyFilePath)) {
        $resolvedKeyFilePath = Resolve-IntuneFileSystemPath -Path $KeyFilePath -MustExist
        $key = $null
        $rsa = $null
        try {
            if ([IO.Path]::GetExtension($resolvedKeyFilePath) -ieq '.pem') {
                $rsa = Get-RsaFromPemFile -Path $resolvedKeyFilePath
            }
            else {
                $key = [Security.Cryptography.CngKey]::Import(
                    [IO.File]::ReadAllBytes($resolvedKeyFilePath),
                    [Security.Cryptography.CngKeyBlobFormat]::new('RSAPUBLICBLOB'))
                $rsa = New-Object Security.Cryptography.RSACng($key)
            }
            return $rsa.Encrypt($PasswordBytes, $padding)
        }
        finally {
            if ($null -ne $rsa) { $rsa.Dispose() }
            if ($null -ne $key) { $key.Dispose() }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ProviderName) -or [string]::IsNullOrWhiteSpace($KeyName)) {
        throw [ArgumentException]::new('KeyFilePath or both ProviderName and KeyName are required.')
    }
    $provider = New-Object Security.Cryptography.CngProvider($ProviderName)
    $key = [Security.Cryptography.CngKey]::Open($KeyName, $provider, [Security.Cryptography.CngKeyOpenOptions]::MachineKey)
    $rsa = New-Object Security.Cryptography.RSACng($key)
    try {
        return $rsa.Encrypt($PasswordBytes, $padding)
    }
    finally {
        $rsa.Dispose()
        $key.Dispose()
    }
}

function Add-IntuneConnectorKeyAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Security.Cryptography.CngKeyCreationParameters]$Parameters,
        [Parameter(Mandatory)][string]$ProviderName
    )

    if ($ProviderName -ne 'Microsoft Software Key Storage Provider') {
        return
    }

    $security = New-Object Security.AccessControl.CryptoKeySecurity
    $administrators = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $localSystem = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $security.AddAccessRule((New-Object Security.AccessControl.CryptoKeyAccessRule($administrators, [Security.AccessControl.CryptoKeyRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)))
    $security.AddAccessRule((New-Object Security.AccessControl.CryptoKeyAccessRule($localSystem, [Security.AccessControl.CryptoKeyRights]::GenericRead, [Security.AccessControl.AccessControlType]::Allow)))
    $daclSecurityInformation = [Security.Cryptography.CngPropertyOptions]4
    $Parameters.Parameters.Add((New-Object Security.Cryptography.CngProperty(
        'Security Descr',
        $security.GetSecurityDescriptorBinaryForm(),
        ([Security.Cryptography.CngPropertyOptions]::Persist -bor $daclSecurityInformation))))
}

function Add-IntuneKspKey {
    <#
    .SYNOPSIS
    Creates an RSA key in a local CNG key storage provider.
    .DESCRIPTION
    Creates a machine CNG key used to encrypt imported PFX passwords.
    .PARAMETER ProviderName
    CNG provider name.
    .PARAMETER KeyName
    Name for the CNG key.
    .PARAMETER KeyLength
    RSA key length in bits. The default is 2048.
    .PARAMETER MakeExportable
    Allows the private key to be exported for connector migration.
    .EXAMPLE
    Add-IntuneKspKey -ProviderName 'Microsoft Software Key Storage Provider' -KeyName 'PfxImportKey'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateNotNullOrEmpty()][string]$ProviderName,
        [Parameter(Mandatory, Position = 1)][ValidateNotNullOrEmpty()][string]$KeyName,
        [ValidateRange(2048, 16384)][int]$KeyLength = 2048,
        [switch]$MakeExportable
    )

    $provider = New-Object Security.Cryptography.CngProvider($ProviderName)
    if ([Security.Cryptography.CngKey]::Exists($KeyName, $provider, [Security.Cryptography.CngKeyOpenOptions]::MachineKey)) {
        throw [InvalidOperationException]::new("CNG key '$KeyName' already exists in '$ProviderName'.")
    }
    if ($PSCmdlet.ShouldProcess("$ProviderName\$KeyName", 'Create machine RSA key')) {
        $parameters = New-Object Security.Cryptography.CngKeyCreationParameters
        $parameters.Provider = $provider
        $parameters.KeyCreationOptions = [Security.Cryptography.CngKeyCreationOptions]::MachineKey
        $parameters.ExportPolicy = if ($MakeExportable) {
            [Security.Cryptography.CngExportPolicies]::AllowExport -bor [Security.Cryptography.CngExportPolicies]::AllowPlaintextExport
        } else {
            [Security.Cryptography.CngExportPolicies]::None
        }
        $parameters.Parameters.Add((New-Object Security.Cryptography.CngProperty('Length', [BitConverter]::GetBytes($KeyLength), [Security.Cryptography.CngPropertyOptions]::None)))
        Add-IntuneConnectorKeyAccess -Parameters $parameters -ProviderName $ProviderName
        $key = [Security.Cryptography.CngKey]::Create([Security.Cryptography.CngAlgorithm]::Rsa, $KeyName, $parameters)
        $key.Dispose()
    }
}

function ConvertTo-IntuneBase64EncodedPfxCertificate {
    <#
    .SYNOPSIS
    Converts a PFX file to a Base64 string.
    .DESCRIPTION
    Reads a PFX file without importing it into a certificate store.
    .PARAMETER CertificatePath
    Path to the PFX file.
    .EXAMPLE
    ConvertTo-IntuneBase64EncodedPfxCertificate -CertificatePath .\user.pfx
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$CertificatePath)
    $resolvedCertificatePath = Resolve-IntuneFileSystemPath -Path $CertificatePath -MustExist
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($resolvedCertificatePath))
}

function Export-IntunePublicKey {
    <#
    .SYNOPSIS
    Exports a local CNG public key.
    .DESCRIPTION
    Exports a machine CNG RSA key as an RSAPUBLICBLOB or PEM public key.
    .PARAMETER ProviderName
    Name of the CNG provider that stores the machine key.
    .PARAMETER KeyName
    Name of the machine CNG key to export.
    .PARAMETER FilePath
    New destination file for the exported public key.
    .PARAMETER FileFormat
    Selects CngBlob or Pem output.
    .EXAMPLE
    Export-IntunePublicKey -ProviderName 'Microsoft Software Key Storage Provider' -KeyName PfxImportKey -FilePath .\key.pem -FileFormat Pem
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$KeyName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FilePath,
        [ValidateSet('CngBlob', 'Pem')][string]$FileFormat = 'CngBlob'
    )

    $resolvedFilePath = Resolve-IntuneFileSystemPath -Path $FilePath
    if (Test-Path -LiteralPath $resolvedFilePath) { throw [IO.IOException]::new("File '$FilePath' already exists.") }
    if ($PSCmdlet.ShouldProcess($resolvedFilePath, "Export $FileFormat public key")) {
        $key = [Security.Cryptography.CngKey]::Open($KeyName, (New-Object Security.Cryptography.CngProvider($ProviderName)), [Security.Cryptography.CngKeyOpenOptions]::MachineKey)
        $rsa = New-Object Security.Cryptography.RSACng($key)
        try {
            if ($FileFormat -eq 'CngBlob') {
                [IO.File]::WriteAllBytes($resolvedFilePath, $key.Export([Security.Cryptography.CngKeyBlobFormat]::new('RSAPUBLICBLOB')))
            }
            else {
                [IO.File]::WriteAllText($resolvedFilePath, (ConvertTo-RsaPublicKeyPem -Rsa $rsa))
            }
        }
        finally {
            $rsa.Dispose()
            $key.Dispose()
        }
    }
}

function Export-IntunePrivateKey {
    <#
    .SYNOPSIS
    Exports an RSA private CNG key.
    .DESCRIPTION
    Exports an exportable machine CNG key as an RSAFULLPRIVATEBLOB.
    .PARAMETER ProviderName
    Name of the CNG provider that stores the machine key.
    .PARAMETER KeyName
    Name of the machine CNG key to export.
    .PARAMETER FilePath
    Destination file that must not already exist.
    .EXAMPLE
    Export-IntunePrivateKey -ProviderName 'Microsoft Software Key Storage Provider' -KeyName PfxImportKey -FilePath .\key.bin
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$KeyName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FilePath
    )

    $resolvedFilePath = Resolve-IntuneFileSystemPath -Path $FilePath
    if (Test-Path -LiteralPath $resolvedFilePath) { throw [IO.IOException]::new("File '$FilePath' already exists.") }
    if ($PSCmdlet.ShouldProcess($resolvedFilePath, 'Export private key')) {
        $key = [Security.Cryptography.CngKey]::Open($KeyName, (New-Object Security.Cryptography.CngProvider($ProviderName)), [Security.Cryptography.CngKeyOpenOptions]::MachineKey)
        try { [IO.File]::WriteAllBytes($resolvedFilePath, $key.Export([Security.Cryptography.CngKeyBlobFormat]::new('RSAFULLPRIVATEBLOB'))) }
        finally { $key.Dispose() }
    }
}

function Import-IntunePrivateKey {
    <#
    .SYNOPSIS
    Imports an RSA private key into a CNG provider.
    .DESCRIPTION
    Imports an RSAFULLPRIVATEBLOB as a machine CNG key.
    .PARAMETER ProviderName
    Name of the destination CNG provider.
    .PARAMETER KeyName
    Name for the imported machine CNG key.
    .PARAMETER FilePath
    Path to an RSAFULLPRIVATEBLOB exported by Export-IntunePrivateKey.
    .PARAMETER MakeExportable
    Allows the imported key to be exported later.
    .EXAMPLE
    Import-IntunePrivateKey -ProviderName 'Microsoft Software Key Storage Provider' -KeyName PfxImportKey -FilePath .\key.bin
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$KeyName,
        [Parameter(Mandatory)][string]$FilePath,
        [switch]$MakeExportable
    )

    $resolvedFilePath = Resolve-IntuneFileSystemPath -Path $FilePath -MustExist
    $provider = New-Object Security.Cryptography.CngProvider($ProviderName)
    if ([Security.Cryptography.CngKey]::Exists($KeyName, $provider, [Security.Cryptography.CngKeyOpenOptions]::MachineKey)) {
        throw [InvalidOperationException]::new("CNG key '$KeyName' already exists in '$ProviderName'.")
    }
    if ($PSCmdlet.ShouldProcess("$ProviderName\$KeyName", 'Import machine RSA private key')) {
        $parameters = New-Object Security.Cryptography.CngKeyCreationParameters
        $parameters.Provider = $provider
        $parameters.KeyCreationOptions = [Security.Cryptography.CngKeyCreationOptions]::MachineKey
        $parameters.ExportPolicy = if ($MakeExportable) {
            [Security.Cryptography.CngExportPolicies]::AllowExport -bor [Security.Cryptography.CngExportPolicies]::AllowPlaintextExport
        } else { [Security.Cryptography.CngExportPolicies]::None }
        $parameters.Parameters.Add((New-Object Security.Cryptography.CngProperty('RSAFULLPRIVATEBLOB', [IO.File]::ReadAllBytes($resolvedFilePath), [Security.Cryptography.CngPropertyOptions]::None)))
        Add-IntuneConnectorKeyAccess -Parameters $parameters -ProviderName $ProviderName
        $key = [Security.Cryptography.CngKey]::Create([Security.Cryptography.CngAlgorithm]::Rsa, $KeyName, $parameters)
        $key.Dispose()
    }
}

function Set-IntuneAuthenticationToken {
    <#
    .SYNOPSIS
    Authenticates the current PowerShell session to Microsoft Graph.
    .DESCRIPTION
    Stores a session-only auth context. Configuration is supplied as command-line parameters, not module manifest PrivateData.
    .PARAMETER ClientId
    Application (client) ID of the Entra application registration.
    .PARAMETER ClientSecret
    Secure client secret for application authentication.
    .PARAMETER TenantId
    Tenant GUID. Required for client-secret authentication and optional for delegated authentication.
    .PARAMETER AdminUserName
    User principal name used as a device-code login hint or with AdminPassword for legacy ROPC.
    .PARAMETER AdminPassword
    Secure password for the legacy ROPC authentication flow.
    .PARAMETER AuthUri
    Entra authority host. Defaults to the commercial cloud host.
    .PARAMETER GraphUri
    Microsoft Graph resource URI. Defaults to the commercial cloud endpoint.
    .PARAMETER SchemaVersion
    Microsoft Graph API version used for Intune requests. Defaults to beta.
    .PARAMETER RedirectUri
    Registered native-client redirect URI used for delegated authentication.
    .EXAMPLE
    Set-IntuneAuthenticationToken -ClientId $clientId -TenantId $tenantId -ClientSecret $secret
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'DeviceCode')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$ClientId,
        [Parameter(Mandatory, ParameterSetName = 'ClientSecret')]
        [Parameter(ParameterSetName = 'Password')]
        [Parameter(ParameterSetName = 'DeviceCode')]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$TenantId,
        [Parameter(ParameterSetName = 'ClientSecret', Mandatory)][Security.SecureString]$ClientSecret,
        [Parameter(ParameterSetName = 'Password', Mandatory)]
        [Parameter(ParameterSetName = 'DeviceCode')]
        [ValidateNotNullOrEmpty()][string]$AdminUserName,
        [Parameter(ParameterSetName = 'Password', Mandatory)][Security.SecureString]$AdminPassword,
        [ValidateNotNullOrEmpty()][string]$AuthUri = $script:CommercialAuthUri,
        [ValidatePattern('^https://')][string]$GraphUri = $script:CommercialGraphUri,
        [ValidateNotNullOrEmpty()][string]$SchemaVersion = 'beta',
        [ValidatePattern('^https://')][string]$RedirectUri = $script:DefaultRedirectUri
    )

    $authority = Get-IntuneAuthorityUri -AuthUri $AuthUri -TenantId $TenantId
    if (-not $PSCmdlet.ShouldProcess($authority, 'Acquire and cache access token for this session')) { return }
    $scope = "$($GraphUri.TrimEnd('/'))/.default"
    $tokenUri = "$authority/oauth2/v2.0/token"
    $context = [pscustomobject]@{
        ClientId = $ClientId; TenantId = $TenantId; AuthUri = $AuthUri; Authority = $authority
        GraphUri = $GraphUri.TrimEnd('/'); SchemaVersion = $SchemaVersion; RedirectUri = $RedirectUri
        AuthenticationType = $PSCmdlet.ParameterSetName; ClientSecret = $null; AccessToken = $null; ExpiresOn = [DateTimeOffset]::MinValue
    }

    if ($PSCmdlet.ParameterSetName -eq 'ClientSecret') {
        $secret = ConvertTo-PlainText -SecureString $ClientSecret
        try {
            $response = Invoke-RestMethod -Method Post -Uri $tokenUri -Body @{
                client_id = $ClientId; client_secret = $secret; scope = $scope; grant_type = 'client_credentials'
            } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        }
        finally { $secret = $null }
        $context.ClientSecret = $ClientSecret
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Password') {
        $password = ConvertTo-PlainText -SecureString $AdminPassword
        try {
            $response = Invoke-RestMethod -Method Post -Uri $tokenUri -Body @{
                client_id = $ClientId; username = $AdminUserName; password = $password; scope = $scope; grant_type = 'password'
            } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        }
        finally { $password = $null }
    }
    else {
        $deviceCode = Invoke-RestMethod -Method Post -Uri "$authority/oauth2/v2.0/devicecode" -Body @{
            client_id = $ClientId; scope = $scope
        } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($deviceCode.device_code)) {
            throw [Security.Authentication.AuthenticationException]::new('The device-code endpoint did not return a device code.')
        }
        if ($AdminUserName) {
            Write-Verbose "Authenticate the device-code flow as '$AdminUserName'."
        }
        Write-Host $deviceCode.message
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$deviceCode.expires_in)
        $response = $null
        do {
            Start-Sleep -Seconds ([Math]::Max(1, [int]$deviceCode.interval))
            try {
                $response = Invoke-RestMethod -Method Post -Uri $tokenUri -Body @{
                    grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; client_id = $ClientId; device_code = $deviceCode.device_code
                } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
            }
            catch {
                if ($_.ErrorDetails.Message -notmatch 'authorization_pending|slow_down') { throw }
            }
        } while ($null -eq $response -and [DateTimeOffset]::UtcNow -lt $deadline)
        if ($null -eq $response) { throw [TimeoutException]::new('Device-code authentication timed out.') }
    }
    if ([string]::IsNullOrWhiteSpace($response.access_token)) { throw [Security.Authentication.AuthenticationException]::new('The token endpoint did not return an access token.') }
    $context.AccessToken = $response.access_token
    $context.ExpiresOn = [DateTimeOffset]::UtcNow.AddSeconds([int]$response.expires_in)
    $script:AuthContext = $context
}

function Remove-IntuneAuthenticationToken {
    <#
    .SYNOPSIS
    Removes the module authentication context from the current session.
    .DESCRIPTION
    Clears the cached access token and secure client-secret reference held by this module.
    .EXAMPLE
    Remove-IntuneAuthenticationToken
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param()
    if ($PSCmdlet.ShouldProcess('current PowerShell session', 'Remove Intune authentication context')) {
        $script:AuthContext = $null
    }
}

function New-IntuneUserPfxCertificate {
    <#
    .SYNOPSIS
    Creates a userPFXCertificate object for Graph import.
    .DESCRIPTION
    Loads the PFX with EphemeralKeySet, detects rsa, ecc, or unknown, and encrypts its password with a CNG key or exported public key.
    .PARAMETER PathToPfxFile
    Path to a PFX file. Use this parameter set or Base64EncodedPfx.
    .PARAMETER Base64EncodedPfx
    Base64-encoded PFX data. Use this parameter set or PathToPfxFile.
    .PARAMETER PfxPassword
    Secure password that protects the PFX private key.
    .PARAMETER UPN
    User principal name to associate with the imported certificate.
    .PARAMETER ProviderName
    CNG provider that contains the password-encryption key when KeyFilePath is not used.
    .PARAMETER KeyName
    Name of the CNG password-encryption key when KeyFilePath is not used.
    .PARAMETER IntendedPurpose
    Intune certificate purpose tag.
    .PARAMETER PaddingScheme
    RSA OAEP padding scheme used to encrypt the PFX password.
    .PARAMETER KeyFilePath
    Public key file exported by Export-IntunePublicKey, in CNG blob or PEM format.
    .EXAMPLE
    New-IntuneUserPfxCertificate -PathToPfxFile .\user.pfx -PfxPassword $password -UPN user@contoso.com -ProviderName 'Microsoft Software Key Storage Provider' -KeyName PfxImportKey
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Path')][string]$PathToPfxFile,
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Base64')][ValidateNotNullOrEmpty()][string]$Base64EncodedPfx,
        [Parameter(Mandatory, Position = 2)][Security.SecureString]$PfxPassword,
        [Parameter(Mandatory, Position = 3)][ValidateNotNullOrEmpty()][string]$UPN,
        [Parameter(Position = 4)][string]$ProviderName,
        [Parameter(Position = 5)][string]$KeyName,
        [Parameter(Position = 6)][ValidateSet('unassigned', 'smimeEncryption', 'smimeSigning', 'vpn', 'wifi')][string]$IntendedPurpose = 'unassigned',
        [Parameter(Position = 7)][ValidateSet('OaepSha256', 'OaepSha384', 'OaepSha512')][string]$PaddingScheme = 'OaepSha512',
        [Parameter(Position = 8)][string]$KeyFilePath
    )

    [byte[]]$pfxData = $null
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $resolvedPfxPath = Resolve-IntuneFileSystemPath -Path $PathToPfxFile -MustExist
        $pfxData = [IO.File]::ReadAllBytes($resolvedPfxPath)
    }
    else {
        $pfxData = [Convert]::FromBase64String($Base64EncodedPfx)
    }
    try {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $pfxData,
            $PfxPassword,
            [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    }
    catch [Security.Cryptography.CryptographicException] {
        throw [ArgumentException]::new('Could not load the PFX. Verify that the PFX data and password are valid.', $_.Exception)
    }

    $thumbprint = $certificate.Thumbprint.ToLowerInvariant()
    $oid = $certificate.PublicKey.Oid.Value
    $startDateTime = $certificate.NotBefore.ToUniversalTime()
    $expirationDateTime = $certificate.NotAfter.ToUniversalTime()
    [byte[]]$passwordBytes = ConvertTo-PasswordBytes -SecureString $PfxPassword
    try {
        $encryptedPassword = Invoke-IntunePasswordEncryption -PasswordBytes $passwordBytes -ProviderName $ProviderName -KeyName $KeyName -KeyFilePath $KeyFilePath -PaddingScheme $PaddingScheme
    }
    finally {
        [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
        $certificate.Dispose()
    }
    $keyAlgorithm = if ($oid -eq '1.2.840.113549.1.1.1') { 'rsa' } elseif ($oid -eq '1.2.840.10045.2.1') { 'ecc' } else { 'unknown' }
    [pscustomobject]@{
        thumbprint = $thumbprint
        keyAlgorithm = $keyAlgorithm
        intendedPurpose = $IntendedPurpose
        userPrincipalName = $UPN
        startDateTime = $startDateTime
        expirationDateTime = $expirationDateTime
        providerName = $ProviderName
        keyName = $KeyName
        paddingScheme = ($PaddingScheme.Substring(0, 1).ToLowerInvariant() + $PaddingScheme.Substring(1))
        encryptedPfxPassword = [Convert]::ToBase64String($encryptedPassword)
        encryptedPfxBlob = $pfxData
        createdDateTime = [DateTime]::UtcNow
        lastModifiedDateTime = [DateTime]::UtcNow
    }
}

function Get-IntuneUserId {
    <#
    .SYNOPSIS
    Gets a Microsoft Graph user ID by UPN.
    .DESCRIPTION
    Uses the authentication context created by Set-IntuneAuthenticationToken.
    .PARAMETER UPN
    User principal name to look up.
    .EXAMPLE
    Get-IntuneUserId -UPN user@contoso.com
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UPN)
    $filter = Escape-IntuneODataLiteral -Value $UPN
    $path = New-IntuneODataFilterPath -Path 'users' -Filter "userPrincipalName eq '$filter'"
    $response = Invoke-IntuneGraphRequest -Method Get -Path $path
    $user = @($response.value)[0]
    if ($null -eq $user -or [string]::IsNullOrWhiteSpace($user.id)) { throw [InvalidOperationException]::new("No user was found for '$UPN'.") }
    return ($user.id -replace '-', '')
}

function Get-IntuneUserPfxCertificate {
    <#
    .SYNOPSIS
    Gets imported Intune PFX certificate records.
    .DESCRIPTION
    Gets all records, records for users, or records matching user/thumbprint pairs.
    .PARAMETER UserThumbprintList
    Objects with User and Thumbprint properties.
    .PARAMETER UserList
    User principal names whose PFX records should be returned.
    .EXAMPLE
    Get-IntuneUserPfxCertificate -UserList user@contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)][object[]]$UserThumbprintList,
        [Parameter(ValueFromPipeline)][string[]]$UserList
    )
    process {
        $queries = @()
        if ($UserThumbprintList) {
            foreach ($item in $UserThumbprintList) {
                if ([string]::IsNullOrWhiteSpace($item.User) -or [string]::IsNullOrWhiteSpace($item.Thumbprint)) { throw [ArgumentException]::new('UserThumbprintList items need User and Thumbprint properties.') }
                $user = Escape-IntuneODataLiteral -Value $item.User.ToLowerInvariant()
                $thumbprint = Escape-IntuneODataLiteral -Value $item.Thumbprint.ToLowerInvariant()
                $queries += New-IntuneODataFilterPath -Path 'deviceManagement/userPfxCertificates' -Filter "tolower(userPrincipalName) eq '$user' and tolower(thumbprint) eq '$thumbprint'"
            }
        }
        elseif ($UserList) {
            foreach ($userName in $UserList) {
                $user = Escape-IntuneODataLiteral -Value $userName.ToLowerInvariant()
                $queries += New-IntuneODataFilterPath -Path 'deviceManagement/userPfxCertificates' -Filter "tolower(userPrincipalName) eq '$user'"
            }
        }
        else { $queries = @('deviceManagement/userPfxCertificates') }
        foreach ($query in $queries) {
            do {
                $response = Invoke-IntuneGraphRequest -Method Get -Path $query
                foreach ($certificate in @($response.value)) { Write-Output $certificate }
                $nextLink = $response.PSObject.Properties['@odata.nextLink']
                $query = if ($null -ne $nextLink) { $nextLink.Value } else { $null }
            } while (-not [string]::IsNullOrWhiteSpace($query))
        }
    }
}

function Import-IntuneUserPfxCertificate {
    <#
    .SYNOPSIS
    Imports or updates user PFX certificate records in Intune.
    .DESCRIPTION
    Posts a record by default, or patches the matching user ID and thumbprint when IsUpdate is supplied.
    .PARAMETER CertificateList
    userPFXCertificate objects created by New-IntuneUserPfxCertificate.
    .PARAMETER IsUpdate
    Patches the existing user and thumbprint record instead of creating a new record.
    .EXAMPLE
    $certificate | Import-IntuneUserPfxCertificate
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][ValidateNotNullOrEmpty()][object[]]$CertificateList,
        [switch]$IsUpdate
    )
    process {
        foreach ($certificate in $CertificateList) {
            $body = ConvertTo-IntuneUserPfxBody -Certificate $certificate
            if ([string]::IsNullOrWhiteSpace($body.thumbprint) -or [string]::IsNullOrWhiteSpace($body.userPrincipalName)) { throw [ArgumentException]::new('Certificate needs thumbprint and userPrincipalName.') }
            $path = 'deviceManagement/userPfxCertificates'
            $method = 'Post'
            if ($IsUpdate) {
                $userId = Get-IntuneUserId -UPN $body.userPrincipalName
                $path = "deviceManagement/userPfxCertificates($userId-$($body.thumbprint))"
                $method = 'Patch'
            }
            if ($PSCmdlet.ShouldProcess("$($body.userPrincipalName)/$($body.thumbprint)", "$method Intune PFX certificate")) {
                Invoke-IntuneGraphRequest -Method $method -Path $path -Body $body | Out-Null
            }
        }
    }
}

function Remove-IntuneUserPfxCertificate {
    <#
    .SYNOPSIS
    Removes user PFX certificate records from Intune.
    .DESCRIPTION
    Removes specified certificate objects, user/thumbprint pairs, or all records for supplied users.
    .PARAMETER CertificateList
    userPFXCertificate objects to remove.
    .PARAMETER UserThumbprintList
    Objects with User and Thumbprint properties identifying records to remove.
    .PARAMETER UserList
    User principal names whose records should be removed. Every imported PFX certificate returned for each supplied user is deleted.
    .EXAMPLE
    Remove-IntuneUserPfxCertificate -UserList user@contoso.com
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Certificate')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Certificate')][object[]]$CertificateList,
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Thumbprint')][object[]]$UserThumbprintList,
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'User')][string[]]$UserList
    )
    process {
        $targets = @()
        if ($PSCmdlet.ParameterSetName -eq 'User') {
            foreach ($user in $UserList) {
                $targets += Get-IntuneUserPfxCertificate -UserList $user | ForEach-Object { [pscustomobject]@{ User = $_.userPrincipalName; Thumbprint = $_.thumbprint } }
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'Certificate') {
            $targets = $CertificateList | ForEach-Object { [pscustomobject]@{ User = $_.userPrincipalName; Thumbprint = $_.thumbprint } }
        }
        else { $targets = $UserThumbprintList }

        foreach ($target in $targets) {
            if ([string]::IsNullOrWhiteSpace($target.User) -or [string]::IsNullOrWhiteSpace($target.Thumbprint)) { throw [ArgumentException]::new('Each removal target needs User and Thumbprint properties.') }
            $userId = Get-IntuneUserId -UPN $target.User
            $name = "$userId-$($target.Thumbprint)"
            if ($PSCmdlet.ShouldProcess($name, 'Remove Intune PFX certificate')) {
                Invoke-IntuneGraphRequest -Method Delete -Path "deviceManagement/userPfxCertificates/$name" | Out-Null
            }
        }
    }
}

function Get-IntunePfxGraphResourceAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$GraphServicePrincipal,
        [Parameter(Mandatory)][ValidateSet('ClientSecret', 'PublicClient', 'Both')][string]$AuthenticationMode
    )

    $required = New-Object Collections.Generic.List[object]
    $requiredValues = New-Object Collections.Generic.List[object]
    if ($AuthenticationMode -in @('ClientSecret', 'Both')) {
        $requiredValues.Add([pscustomobject]@{ Value = 'DeviceManagementConfiguration.ReadWrite.All'; Type = 'Role' })
        $requiredValues.Add([pscustomobject]@{ Value = 'User.Read.All'; Type = 'Role' })
    }
    if ($AuthenticationMode -in @('PublicClient', 'Both')) {
        $requiredValues.Add([pscustomobject]@{ Value = 'DeviceManagementConfiguration.ReadWrite.All'; Type = 'Scope' })
        $requiredValues.Add([pscustomobject]@{ Value = 'User.Read.All'; Type = 'Scope' })
        $requiredValues.Add([pscustomobject]@{ Value = 'User.Read'; Type = 'Scope' })
    }

    foreach ($permission in $requiredValues) {
        if ($permission.Type -eq 'Role') {
            $source = @($GraphServicePrincipal.AppRoles | Where-Object { $_.Value -eq $permission.Value -and $_.IsEnabled })
        }
        else {
            $source = @($GraphServicePrincipal.Oauth2PermissionScopes | Where-Object { $_.Value -eq $permission.Value -and $_.IsEnabled })
        }
        if ($source.Count -ne 1) {
            throw [InvalidOperationException]::new("Microsoft Graph does not expose exactly one enabled $($permission.Type) '$($permission.Value)' in this tenant.")
        }
        $required.Add([pscustomobject]@{ Id = $source[0].Id; Type = $permission.Type; Value = $permission.Value })
    }
    return $required.ToArray()
}

function Merge-IntunePfxRequiredResourceAccess {
    [CmdletBinding()]
    param(
        [AllowNull()]$ExistingRequiredResourceAccess,
        [Parameter(Mandatory)][string]$GraphApplicationId,
        [Parameter(Mandatory)][object[]]$RequiredAccess
    )

    $merged = New-Object Collections.Generic.List[object]
    foreach ($entry in @($ExistingRequiredResourceAccess)) {
        $resourceAccess = New-Object Collections.Generic.List[object]
        foreach ($access in @($entry.ResourceAccess)) {
            $resourceAccess.Add(@{ Id = $access.Id; Type = $access.Type })
        }
        $merged.Add(@{ ResourceAppId = $entry.ResourceAppId; ResourceAccess = $resourceAccess.ToArray() })
    }

    $graphEntry = @($merged | Where-Object { $_.ResourceAppId -eq $GraphApplicationId })[0]
    if ($null -eq $graphEntry) {
        $graphEntry = @{ ResourceAppId = $GraphApplicationId; ResourceAccess = @() }
        $merged.Add($graphEntry)
    }
    $graphAccess = New-Object Collections.Generic.List[object]
    foreach ($access in @($graphEntry.ResourceAccess)) {
        $graphAccess.Add(@{ Id = $access.Id; Type = $access.Type })
    }
    foreach ($access in $RequiredAccess) {
        if (@($graphAccess | Where-Object { $_.Id -eq $access.Id -and $_.Type -eq $access.Type }).Count -eq 0) {
            $graphAccess.Add(@{ Id = $access.Id; Type = $access.Type })
        }
    }
    $graphEntry.ResourceAccess = $graphAccess.ToArray()
    return $merged.ToArray()
}

function Test-IntunePfxApplicationConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)][object[]]$RequiredAccess,
        [Parameter(Mandatory)][ValidateSet('ClientSecret', 'PublicClient', 'Both')][string]$AuthenticationMode,
        [Parameter(Mandatory)][string]$RedirectUri
    )

    $currentAccess = @($Application.RequiredResourceAccess | Where-Object { $_.ResourceAppId -eq '00000003-0000-0000-c000-000000000000' } | ForEach-Object { $_.ResourceAccess })
    $missingPermissions = New-Object Collections.Generic.List[object]
    foreach ($requiredPermission in $RequiredAccess) {
        if (@($currentAccess | Where-Object { $_.Id -eq $requiredPermission.Id -and $_.Type -eq $requiredPermission.Type }).Count -eq 0) {
            $missingPermissions.Add($requiredPermission)
        }
    }
    $publicClientNeeded = $AuthenticationMode -in @('PublicClient', 'Both')
    $redirects = @($Application.PublicClient.RedirectUris)
    return [pscustomobject]@{
        MissingPermissions = $missingPermissions.ToArray()
        PublicClientNeedsUpdate = $publicClientNeeded -and ((-not $Application.IsFallbackPublicClient) -or ($redirects -notcontains $RedirectUri))
    }
}

function Get-IntuneMgGraphContext {
    [CmdletBinding()]
    param()
    Get-MgContext
}

function Connect-IntuneMgGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Parameters)
    Connect-MgGraph @Parameters
}

function Get-IntuneMgServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Filter,
        [Parameter(Mandatory)][string[]]$Property
    )
    Get-MgServicePrincipal -Filter $Filter -Property $Property -All
}

function Get-IntuneMgApplication {
    [CmdletBinding(DefaultParameterSetName = 'Filter')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Filter')][string]$Filter,
        [Parameter(Mandatory, ParameterSetName = 'Id')][string]$ApplicationId,
        [Parameter(Mandatory)][string[]]$Property
    )
    if ($PSCmdlet.ParameterSetName -eq 'Filter') {
        Get-MgApplication -Filter $Filter -Property $Property -All
    }
    else {
        Get-MgApplication -ApplicationId $ApplicationId -Property $Property
    }
}

function New-IntuneMgApplication {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Parameters)
    New-MgApplication @Parameters
}

function Update-IntuneMgApplication {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Parameters)
    Update-MgApplication @Parameters
}

function New-IntuneMgServicePrincipal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppId)
    New-MgServicePrincipal -AppId $AppId
}

function Add-IntuneMgApplicationPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][hashtable]$PasswordCredential
    )
    Add-MgApplicationPassword -ApplicationId $ApplicationId -PasswordCredential $PasswordCredential
}

function Initialize-IntunePfxImportApplication {
    <#
    .SYNOPSIS
    Creates, validates, or updates a Microsoft Entra application for Intune PFX import.
    .DESCRIPTION
    Uses Microsoft Graph PowerShell SDK application cmdlets to configure required Microsoft Graph application and delegated permissions.
    It creates the corresponding service principal, but never claims to grant tenant admin consent. The returned AdminConsentUri must be opened by an authorized tenant administrator.
    .PARAMETER DisplayName
    Display name for a new or discovered application registration.
    .PARAMETER ExistingApplicationId
    Application (client) ID of an existing registration to validate or update.
    .PARAMETER AuthenticationMode
    Configures ClientSecret, PublicClient, or both permission models.
    .PARAMETER ValidateOnly
    Reports missing configuration without creating or changing tenant objects.
    .PARAMETER ConnectGraph
    Connects through Microsoft Graph PowerShell when no existing Graph SDK context is available.
    .PARAMETER TenantId
    Tenant GUID to validate against the active Graph SDK connection.
    .PARAMETER AuthUri
    Entra authority host returned for Set-IntuneAuthenticationToken.
    .PARAMETER GraphUri
    Microsoft Graph resource URI returned for Set-IntuneAuthenticationToken.
    .PARAMETER SchemaVersion
    Microsoft Graph API version returned for Set-IntuneAuthenticationToken.
    .PARAMETER RedirectUri
    Native-client redirect URI configured for public-client authentication.
    .PARAMETER CreateClientSecret
    Creates an application client secret and returns its one-time value as a SecureString.
    .EXAMPLE
    $setup = Initialize-IntunePfxImportApplication -DisplayName 'Intune PFX Import' -AuthenticationMode Both -ConnectGraph
    $authParameters = $setup.SetIntuneAuthenticationTokenParameters
    Set-IntuneAuthenticationToken @authParameters -ClientSecret $setup.ClientSecret
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(ParameterSetName = 'ByName')][ValidateNotNullOrEmpty()][string]$DisplayName = 'Intune PFX Import',
        [Parameter(Mandatory, ParameterSetName = 'ByApplicationId')][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$ExistingApplicationId,
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$TenantId,
        [ValidateSet('ClientSecret', 'PublicClient', 'Both')][string]$AuthenticationMode = 'Both',
        [ValidateNotNullOrEmpty()][string]$AuthUri = $script:CommercialAuthUri,
        [ValidatePattern('^https://')][string]$GraphUri = $script:CommercialGraphUri,
        [ValidateNotNullOrEmpty()][string]$SchemaVersion = 'beta',
        [ValidatePattern('^https://')][string]$RedirectUri = $script:DefaultRedirectUri,
        [switch]$CreateClientSecret,
        [switch]$ValidateOnly,
        [switch]$ConnectGraph
    )

    $requiredCommands = @('Get-MgContext', 'Get-MgServicePrincipal', 'Get-MgApplication', 'New-MgApplication', 'Update-MgApplication', 'New-MgServicePrincipal')
    foreach ($command in $requiredCommands) {
        if ($null -eq (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            throw [InvalidOperationException]::new("Microsoft Graph PowerShell SDK command '$command' is unavailable. Install Microsoft.Graph.Applications and Microsoft.Graph.Authentication.")
        }
    }

    $requestedGraphEnvironment = if ($GraphUri -eq $script:CommercialGraphUri) {
        'Global'
    }
    elseif ($GraphUri -eq 'https://graph.microsoft.us') {
        'USGov'
    }
    else {
        throw [ArgumentException]::new("Application onboarding does not support the Microsoft Graph endpoint '$GraphUri'. Connect and configure the application manually for other sovereign clouds.")
    }

    $graphContext = Get-IntuneMgGraphContext
    if ($null -eq $graphContext) {
        if (-not $ConnectGraph) {
            throw [InvalidOperationException]::new('No Microsoft Graph PowerShell SDK connection exists. Run Connect-MgGraph with Application.ReadWrite.All and Application.Read.All, or call this function with -ConnectGraph.')
        }
        $connectTarget = if ($TenantId) { $TenantId } else { 'home tenant' }
        if (-not $PSCmdlet.ShouldProcess($connectTarget, 'Connect Microsoft Graph PowerShell SDK')) { return }
        $connectParameters = @{ Scopes = @('Application.ReadWrite.All', 'Application.Read.All') }
        if ($TenantId) { $connectParameters.TenantId = $TenantId }
        if ($requestedGraphEnvironment -ne 'Global') { $connectParameters.Environment = $requestedGraphEnvironment }
        Connect-IntuneMgGraph -Parameters $connectParameters | Out-Null
        $graphContext = Get-IntuneMgGraphContext
    }
    if ($null -eq $graphContext -or [string]::IsNullOrWhiteSpace($graphContext.TenantId)) {
        throw [InvalidOperationException]::new('Microsoft Graph PowerShell did not return a tenant context after authentication.')
    }
    if ($TenantId -and $TenantId -ne $graphContext.TenantId) {
        throw [InvalidOperationException]::new("Connected Graph tenant '$($graphContext.TenantId)' does not match TenantId '$TenantId'.")
    }
    $connectedGraphEnvironment = if (
        $null -ne $graphContext.PSObject.Properties['Environment'] -and
        -not [string]::IsNullOrWhiteSpace($graphContext.Environment)
    ) { $graphContext.Environment } else { 'Global' }
    if ($connectedGraphEnvironment -ne $requestedGraphEnvironment) {
        throw [InvalidOperationException]::new("Connected Graph environment '$connectedGraphEnvironment' does not match the environment '$requestedGraphEnvironment' selected by GraphUri '$GraphUri'.")
    }
    $tenant = $graphContext.TenantId

    $graphServicePrincipal = @(Get-IntuneMgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'" -Property 'id,appId,appRoles,oauth2PermissionScopes')
    if ($graphServicePrincipal.Count -ne 1) {
        throw [InvalidOperationException]::new('Could not resolve the Microsoft Graph service principal in the connected tenant.')
    }
    $requiredAccess = Get-IntunePfxGraphResourceAccess -GraphServicePrincipal $graphServicePrincipal[0] -AuthenticationMode $AuthenticationMode

    if ($PSCmdlet.ParameterSetName -eq 'ByApplicationId') {
        $application = Get-IntuneMgApplication -Filter "appId eq '$ExistingApplicationId'" -Property 'id,appId,displayName,requiredResourceAccess,publicClient,isFallbackPublicClient'
    }
    else {
        $application = Get-IntuneMgApplication -Filter "displayName eq '$($DisplayName.Replace("'", "''"))'" -Property 'id,appId,displayName,requiredResourceAccess,publicClient,isFallbackPublicClient'
    }
    $application = @($application)
    if ($application.Count -gt 1) {
        throw [InvalidOperationException]::new('More than one application matched. Re-run with -ExistingApplicationId.')
    }

    $clientSecret = $null
    $changes = New-Object Collections.Generic.List[string]
    if ($application.Count -eq 0) {
        if ($ValidateOnly) {
            throw [InvalidOperationException]::new('ValidateOnly cannot find the requested application registration.')
        }
        if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create Intune PFX import application registration')) { return }
        $newGraphResourceAccess = @($requiredAccess | ForEach-Object { @{ Id = $_.Id; Type = $_.Type } })
        $newApplicationParameters = @{
            DisplayName = $DisplayName
            SignInAudience = 'AzureADMyOrg'
            RequiredResourceAccess = @(@{
                ResourceAppId = '00000003-0000-0000-c000-000000000000'
                ResourceAccess = $newGraphResourceAccess
            })
        }
        if ($AuthenticationMode -in @('PublicClient', 'Both')) {
            $newApplicationParameters.IsFallbackPublicClient = $true
            $newApplicationParameters.PublicClient = @{ RedirectUris = @($RedirectUri) }
        }
        $application = @(New-IntuneMgApplication -Parameters $newApplicationParameters)
        $changes.Add('ApplicationCreated')
    }
    else {
        $application = $application[0]
        $configuration = Test-IntunePfxApplicationConfiguration -Application $application -RequiredAccess $requiredAccess -AuthenticationMode $AuthenticationMode -RedirectUri $RedirectUri
        if ($configuration.MissingPermissions.Count -gt 0) { $changes.Add('RequiredResourceAccess') }
        if ($configuration.PublicClientNeedsUpdate) { $changes.Add('PublicClient') }
        if ($changes.Count -gt 0 -and -not $ValidateOnly) {
            if ($PSCmdlet.ShouldProcess($application.DisplayName, "Update Intune PFX import application configuration: $($changes -join ', ')")) {
                $updateParameters = @{
                    ApplicationId = $application.Id
                    RequiredResourceAccess = Merge-IntunePfxRequiredResourceAccess -ExistingRequiredResourceAccess $application.RequiredResourceAccess -GraphApplicationId '00000003-0000-0000-c000-000000000000' -RequiredAccess $requiredAccess
                }
                if ($AuthenticationMode -in @('PublicClient', 'Both')) {
                    $updateParameters.IsFallbackPublicClient = $true
                    $updateParameters.PublicClient = @{ RedirectUris = @($application.PublicClient.RedirectUris + $RedirectUri | Select-Object -Unique) }
                }
                Update-IntuneMgApplication -Parameters $updateParameters | Out-Null
                $application = @(Get-IntuneMgApplication -ApplicationId $application.Id -Property 'id,appId,displayName,requiredResourceAccess,publicClient,isFallbackPublicClient')[0]
            }
        }
    }

    $servicePrincipal = @(Get-IntuneMgServicePrincipal -Filter "appId eq '$($application.AppId)'" -Property 'id,appId,displayName')
    if ($servicePrincipal.Count -gt 1) { throw [InvalidOperationException]::new("More than one service principal exists for application '$($application.AppId)'.") }
    if ($servicePrincipal.Count -eq 0) {
        $changes.Add('ServicePrincipal')
        if (-not $ValidateOnly -and $PSCmdlet.ShouldProcess($application.DisplayName, 'Create application service principal')) {
            $servicePrincipal = @(New-IntuneMgServicePrincipal -AppId $application.AppId)
        }
    }

    if ($CreateClientSecret) {
        if ($AuthenticationMode -eq 'PublicClient') { throw [ArgumentException]::new('CreateClientSecret requires AuthenticationMode ClientSecret or Both.') }
        if ($ValidateOnly) { $changes.Add('ClientSecret') }
        elseif ($PSCmdlet.ShouldProcess($application.DisplayName, 'Create application client secret')) {
            if ($null -eq (Get-Command -Name Add-MgApplicationPassword -ErrorAction SilentlyContinue)) {
                throw [InvalidOperationException]::new("Microsoft Graph PowerShell SDK command 'Add-MgApplicationPassword' is unavailable. Install Microsoft.Graph.Applications.")
            }
            $passwordCredential = Add-IntuneMgApplicationPassword -ApplicationId $application.Id -PasswordCredential @{ DisplayName = "Intune PFX Import $([DateTime]::UtcNow.ToString('yyyy-MM-dd'))" }
            if ([string]::IsNullOrWhiteSpace($passwordCredential.SecretText)) {
                throw [InvalidOperationException]::new('Microsoft Graph did not return the one-time client secret value.')
            }
            $clientSecret = ConvertTo-SecureString $passwordCredential.SecretText -AsPlainText -Force
            $changes.Add('ClientSecret')
        }
    }

    $authority = Get-IntuneAuthorityUri -AuthUri $AuthUri -TenantId $tenant
    $adminConsentUri = "$authority/adminconsent?client_id=$($application.AppId)"
    [pscustomobject]@{
        ApplicationId = $application.AppId
        ObjectId = $application.Id
        ServicePrincipalId = if ($servicePrincipal.Count -eq 1) { $servicePrincipal[0].Id } else { $null }
        TenantId = $tenant
        AuthenticationMode = $AuthenticationMode
        ChangesRequiredOrApplied = $changes.ToArray()
        AdminConsentRequired = $true
        AdminConsentUri = $adminConsentUri
        ClientSecret = $clientSecret
        SetIntuneAuthenticationTokenParameters = [ordered]@{
            ClientId = $application.AppId
            TenantId = $tenant
            AuthUri = $AuthUri
            GraphUri = $GraphUri
            SchemaVersion = $SchemaVersion
            RedirectUri = $RedirectUri
        }
        AdminConsentInstructions = if ($AuthenticationMode -in @('ClientSecret', 'Both')) {
            'This application requests Microsoft Graph application permissions. A Privileged Role Administrator or Global Administrator must review and grant tenant-wide admin consent. Application Administrator and Cloud Application Administrator can configure applications but cannot grant Microsoft Graph application permissions. This command only configures requested permissions; it does not grant consent.'
        }
        else {
            'This application requests delegated permissions. An authorized tenant administrator must review and grant tenant-wide consent when required by the configured scopes. This command only configures requested permissions; it does not grant consent.'
        }
    }
}

Export-ModuleMember -Function @(
    'Add-IntuneKspKey',
    'ConvertTo-IntuneBase64EncodedPfxCertificate',
    'Export-IntunePrivateKey',
    'Export-IntunePublicKey',
    'Get-IntuneUserId',
    'Get-IntuneUserPfxCertificate',
    'Import-IntunePrivateKey',
    'Import-IntuneUserPfxCertificate',
    'Initialize-IntunePfxImportApplication',
    'New-IntuneUserPfxCertificate',
    'Remove-IntuneAuthenticationToken',
    'Remove-IntuneUserPfxCertificate',
    'Set-IntuneAuthenticationToken'
)
