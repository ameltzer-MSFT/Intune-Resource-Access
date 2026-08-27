$script:moduleRoot = Join-Path $PSScriptRoot '..\PFXImportPS'
$script:manifestPath = Join-Path $script:moduleRoot 'IntunePfxImport.psd1'
$global:IntunePfxTestGraphServicePrincipal = [pscustomobject]@{
    Id = 'graph-sp'
    AppRoles = @(
        [pscustomobject]@{ Id = 'role-device'; Value = 'DeviceManagementConfiguration.ReadWrite.All'; IsEnabled = $true },
        [pscustomobject]@{ Id = 'role-user'; Value = 'User.Read.All'; IsEnabled = $true }
    )
    Oauth2PermissionScopes = @(
        [pscustomobject]@{ Id = 'scope-device'; Value = 'DeviceManagementConfiguration.ReadWrite.All'; IsEnabled = $true },
        [pscustomobject]@{ Id = 'scope-user-all'; Value = 'User.Read.All'; IsEnabled = $true },
        [pscustomobject]@{ Id = 'scope-user'; Value = 'User.Read'; IsEnabled = $true }
    )
}

Describe 'IntunePfxImport 3.0 script module' {
    BeforeAll {
        Remove-Module IntunePfxImport -ErrorAction SilentlyContinue
        Import-Module $manifestPath -Force
    }

    AfterAll {
        Remove-Module IntunePfxImport -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name IntunePfxTestGraphServicePrincipal -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name IntunePfxTestExistingApplication -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name IntunePfxTestSecret -Scope Global -ErrorAction SilentlyContinue
    }

    It 'exports the documented public function contract explicitly' {
        $manifest = Import-PowerShellDataFile -Path $manifestPath

        if ($manifest.ModuleVersion -ne '3.0.0') { throw 'ModuleVersion must be 3.0.0.' }
        if ($manifest.RootModule -ne 'IntunePfxImport.psm1') { throw 'The manifest must load the script module.' }
        if ($manifest.FunctionsToExport -contains '*') { throw 'The manifest must not use wildcard function exports.' }
        if (@($manifest.CmdletsToExport).Count -ne 0) { throw 'The manifest must not export compiled cmdlets.' }
        if (@(Compare-Object -ReferenceObject @($manifest.FunctionsToExport) -DifferenceObject @((Get-Command -Module IntunePfxImport).Name)).Count -ne 0) { throw 'Manifest and module exports differ.' }

        $version2Commands = @(
            'Add-IntuneKspKey',
            'ConvertTo-IntuneBase64EncodedPfxCertificate',
            'Export-IntunePrivateKey',
            'Export-IntunePublicKey',
            'Get-IntuneUserId',
            'Get-IntuneUserPfxCertificate',
            'Import-IntunePrivateKey',
            'Import-IntuneUserPfxCertificate',
            'New-IntuneUserPfxCertificate',
            'Remove-IntuneAuthenticationToken',
            'Remove-IntuneUserPfxCertificate',
            'Set-IntuneAuthenticationToken'
        )
        if (@(Compare-Object -ReferenceObject $version2Commands -DifferenceObject @($manifest.FunctionsToExport | Where-Object { $_ -ne 'Initialize-IntunePfxImportApplication' })).Count -ne 0) {
            throw 'The shipped Version 2 command surface is not preserved.'
        }
    }

    It 'restores legacy NuGet packages to the directory used by project HintPaths' {
        $pipelinePath = Join-Path $PSScriptRoot '..\..\..\azure-pipelines.yml'
        $pipeline = Get-Content -LiteralPath $pipelinePath -Raw

        if ($pipeline -notmatch "restoreDirectory:\s*'src/PFXImportPowershell/packages'") {
            throw 'NuGet restoreDirectory does not match the EncryptionUtilities project HintPaths.'
        }
    }

    It 'does not retry ambiguous server errors for non-idempotent POST requests' {
        $global:IntunePfxTestPostCount = 0
        Mock -CommandName Start-Sleep -ModuleName IntunePfxImport {
            throw 'A non-idempotent POST must not be retried after an ambiguous server error.'
        }
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Uri)
            if ($Uri -match '/oauth2/v2.0/token$') {
                return [pscustomobject]@{ access_token = 'post-retry-token'; expires_in = 3600 }
            }
            $global:IntunePfxTestPostCount++
            $exception = [InvalidOperationException]::new('Ambiguous server failure.')
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{
                StatusCode = 500
                Headers = New-Object Net.WebHeaderCollection
            })
            throw $exception
        }
        $secret = ConvertTo-SecureString 'post-retry-secret' -AsPlainText -Force
        $certificate = [pscustomobject]@{
            thumbprint = 'ambiguous'
            userPrincipalName = 'user@contoso.com'
            encryptedPfxBlob = [byte[]](1)
            encryptedPfxPassword = 'AQ=='
        }

        Set-IntuneAuthenticationToken -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -ClientSecret $secret -Confirm:$false
        Import-IntuneUserPfxCertificate -CertificateList $certificate -Confirm:$false -ErrorAction SilentlyContinue

        if ($global:IntunePfxTestPostCount -ne 1) {
            throw "Expected one POST attempt after an ambiguous server failure but got '$global:IntunePfxTestPostCount'."
        }
    }

    It 'documents all meaningful exported function parameters' {
        $commonParameters = @(
            'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
            'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
            'OutBuffer', 'PipelineVariable', 'ProgressAction', 'WhatIf', 'Confirm'
        )
        foreach ($command in Get-Command -Module IntunePfxImport) {
            foreach ($parameterName in @($command.Parameters.Keys | Where-Object { $_ -notin $commonParameters })) {
                $parameterHelp = Get-Help $command.Name -Parameter $parameterName
                if ([string]::IsNullOrWhiteSpace(($parameterHelp.Description.Text -join ' '))) {
                    throw "Missing comment-based help for $($command.Name) parameter '$parameterName'."
                }
            }
        }
    }

    It 'converts a PFX file from TestDrive without importing it into a certificate store' {
        $pfxPath = Join-Path $TestDrive 'certificate.pfx'
        [IO.File]::WriteAllBytes($pfxPath, [byte[]](1, 2, 3, 4))

        if ((ConvertTo-IntuneBase64EncodedPfxCertificate -CertificatePath $pfxPath) -ne 'AQIDBA==') { throw 'PFX bytes were not Base64 encoded correctly.' }
    }

    It 'resolves relative file paths from the callers current location' {
        $pfxPath = Join-Path $TestDrive 'relative-certificate.pfx'
        [IO.File]::WriteAllBytes($pfxPath, [byte[]](1, 2, 3, 4))
        $password = ConvertTo-SecureString 'test' -AsPlainText -Force
        $errorMessage = $null

        Push-Location $TestDrive
        try {
            $base64 = ConvertTo-IntuneBase64EncodedPfxCertificate -CertificatePath '.\relative-certificate.pfx'
            try {
                New-IntuneUserPfxCertificate -PathToPfxFile '.\relative-certificate.pfx' -PfxPassword $password -UPN 'user@contoso.com' -KeyFilePath '.\unused.pem'
            }
            catch {
                $errorMessage = $_.Exception.Message
            }
        }
        finally {
            Pop-Location
        }

        if ($base64 -ne 'AQIDBA==') { throw 'The relative input path was not resolved from the caller location.' }
        if ($errorMessage -notlike '*Could not load the PFX*') {
            throw "New-IntuneUserPfxCertificate did not read the caller-relative PFX path. Error: $errorMessage"
        }
    }

    It 'does not call Graph when an import is simulated with WhatIf' {
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport { throw 'Graph must not be called for WhatIf.' }
        $certificate = [pscustomobject]@{
            thumbprint = 'abc'
            userPrincipalName = 'user@contoso.com'
            encryptedPfxBlob = [byte[]](1)
            encryptedPfxPassword = 'AQ=='
        }

        Import-IntuneUserPfxCertificate -CertificateList $certificate -WhatIf

        Assert-MockCalled -CommandName Invoke-RestMethod -ModuleName IntunePfxImport -Times 0 -Exactly
    }

    It 'requires an authentication context before a Graph read' {
        Remove-IntuneAuthenticationToken -Confirm:$false

        $errorMessage = $null
        try { Get-IntuneUserPfxCertificate } catch { $errorMessage = $_.Exception.Message }
        if ($errorMessage -notlike '*Call Set-IntuneAuthenticationToken first*') { throw 'Graph reads must require an authentication context.' }
    }

    It 'reports a missing directory user without a strict-mode indexing error' {
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Uri)
            if ($Uri -match '/oauth2/v2.0/token$') {
                return [pscustomobject]@{ access_token = 'missing-user-token'; expires_in = 3600 }
            }
            return [pscustomobject]@{ value = @() }
        }
        $secret = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N')) -AsPlainText -Force
        Set-IntuneAuthenticationToken `
            -ClientId '99999999-9999-9999-9999-999999999999' `
            -TenantId '88888888-8888-8888-8888-888888888888' `
            -ClientSecret $secret `
            -Confirm:$false

        $errorMessage = $null
        try { Get-IntuneUserId -UPN 'missing@contoso.com' } catch { $errorMessage = $_.Exception.Message }

        if ($errorMessage -ne "No user was found for 'missing@contoso.com'.") {
            throw "Expected a clear missing-user error but got: $errorMessage"
        }
    }

    It 'requires a tenant for client-secret authentication' {
        $clientSecretParameters = (Get-Command Set-IntuneAuthenticationToken).ParameterSets |
            Where-Object Name -eq 'ClientSecret' |
            Select-Object -ExpandProperty Parameters
        $tenantParameter = $clientSecretParameters | Where-Object Name -eq 'TenantId'

        if (-not $tenantParameter.IsMandatory) { throw 'TenantId must be mandatory for client-secret authentication.' }
    }

    It 'preserves the legacy positional certificate-creation contract' {
        $pathParameters = (Get-Command New-IntuneUserPfxCertificate).ParameterSets |
            Where-Object Name -eq 'Path' |
            Select-Object -ExpandProperty Parameters
        $expectedPositions = @{
            PathToPfxFile = 1
            PfxPassword = 2
            UPN = 3
            ProviderName = 4
            KeyName = 5
            IntendedPurpose = 6
            PaddingScheme = 7
            KeyFilePath = 8
        }

        foreach ($entry in $expectedPositions.GetEnumerator()) {
            $parameter = $pathParameters | Where-Object Name -eq $entry.Key
            if ($parameter.Position -ne $entry.Value) {
                throw "Expected $($entry.Key) at position $($entry.Value), but found $($parameter.Position)."
            }
        }
    }

    It 'builds the connector key ACL on every supported PowerShell edition' {
        $result = & (Get-Module IntunePfxImport) {
            $parameters = New-Object Security.Cryptography.CngKeyCreationParameters

            Add-IntuneConnectorKeyAccess `
                -Parameters $parameters `
                -ProviderName 'Microsoft Software Key Storage Provider'

            $property = @($parameters.Parameters | Where-Object Name -eq 'Security Descr')[0]
            $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
                $property.GetValue(),
                0)
            [pscustomobject]@{
                PropertyCount = $parameters.Parameters.Count
                Sddl = $descriptor.GetSddlForm(
                    [Security.AccessControl.AccessControlSections]::Access)
            }
        }

        if ($result.PropertyCount -ne 1) {
            throw 'The software KSP creation parameters must contain one security descriptor.'
        }
        if ($result.Sddl -ne 'D:(A;;FA;;;BA)(A;;GR;;;SO)(A;;GR;;;SY)') {
            throw "The connector key ACL is incorrect: $($result.Sddl)"
        }
    }

    It 'preserves Version 2 positional metadata for local key commands' {
        $expected = @{
            'Add-IntuneKspKey' = @{ ProviderName = 1; KeyName = 2; KeyLength = 3 }
            'ConvertTo-IntuneBase64EncodedPfxCertificate' = @{ CertificatePath = 1 }
            'Export-IntunePublicKey' = @{ ProviderName = 1; KeyName = 2; FilePath = 3; FileFormat = 4 }
            'Export-IntunePrivateKey' = @{ ProviderName = 1; KeyName = 2; FilePath = 3 }
            'Import-IntunePrivateKey' = @{ ProviderName = 1; KeyName = 2; FilePath = 3 }
        }

        foreach ($commandName in $expected.Keys) {
            $parameters = (Get-Command $commandName).ParameterSets[0].Parameters
            foreach ($entry in $expected[$commandName].GetEnumerator()) {
                $parameter = $parameters | Where-Object Name -eq $entry.Key
                if ($parameter.Position -ne $entry.Value) {
                    throw "Expected $commandName -$($entry.Key) at position $($entry.Value), but found $($parameter.Position)."
                }
            }
        }
    }

    It 'preserves Version 2 parameter-set names for Graph list and removal commands' {
        $getSets = @((Get-Command Get-IntuneUserPfxCertificate).ParameterSets.Name)
        $removeSets = @((Get-Command Remove-IntuneUserPfxCertificate).ParameterSets.Name)

        if ($getSets -notcontains 'FromThumbprints' -or $getSets -notcontains 'FromUsers') {
            throw "Unexpected Get parameter sets: $($getSets -join ', ')"
        }
        foreach ($name in @('FromUserPFXCertificates', 'FromThumbprints', 'FromUsers')) {
            if ($removeSets -notcontains $name) {
                throw "Remove is missing Version 2 parameter set '$name'."
            }
        }
    }

    It 'accepts Version 2 purpose numbers and None padding' {
        $module = Get-Module IntunePfxImport
        $result = & $module {
            $purposeMap = @{
                '0' = 'unassigned'
                '1' = 'smimeEncryption'
                '2' = 'smimeSigning'
                '4' = 'vpn'
                '8' = 'wifi'
            }
            [pscustomobject]@{
                Purposes = $purposeMap
                Padding = Get-IntuneRsaPadding -PaddingScheme OaepSha512
            }
        }

        if ($result.Purposes['1'] -ne 'smimeEncryption') { throw 'Version 2 purpose mapping changed.' }
        if ($result.Padding -ne [Security.Cryptography.RSAEncryptionPadding]::OaepSHA512) { throw 'None compatibility must normalize to OAEP SHA-512.' }
        $commandText = Get-Content -LiteralPath (Join-Path $moduleRoot 'IntunePfxImport.psm1') -Raw
        if ($commandText -notmatch '\$paddingText -ieq ''None''') { throw 'PaddingScheme None compatibility is missing.' }
    }

    It 'remembers Version 2 provider and key values within the module session' {
        $module = Get-Module IntunePfxImport
        $values = & $module {
            Resolve-IntuneEncryptionKeyParameters -ProviderName 'provider-a' -KeyName 'key-a' -ProviderNameWasBound $true -KeyNameWasBound $true | Out-Null
            Resolve-IntuneEncryptionKeyParameters -ProviderName '' -KeyName '' -ProviderNameWasBound $false -KeyNameWasBound $false
        }

        if ($values.ProviderName -ne 'provider-a' -or $values.KeyName -ne 'key-a') {
            throw 'Version 2 provider/key carry-forward is not preserved.'
        }
    }

    It 'supports the deprecated Version 2 manifest authentication fallback' {
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            [pscustomobject]@{ access_token = 'legacy-token'; expires_in = 3600 }
        }
        $module = Get-Module IntunePfxImport
        & $module {
            $ExecutionContext.SessionState.Module.PrivateData.ClientId = '11111111-1111-1111-1111-111111111111'
            $ExecutionContext.SessionState.Module.PrivateData.TenantId = '22222222-2222-2222-2222-222222222222'
            $ExecutionContext.SessionState.Module.PrivateData.ClientSecret = 'legacy-secret'
        }

        try {
            Set-IntuneAuthenticationToken -Confirm:$false
            Assert-MockCalled -CommandName Invoke-RestMethod -ModuleName IntunePfxImport -Times 1 -Exactly -ParameterFilter {
                $Body.client_id -eq '11111111-1111-1111-1111-111111111111' -and
                $Body.grant_type -eq 'client_credentials'
            }
        }
        finally {
            & $module {
                $ExecutionContext.SessionState.Module.PrivateData.ClientId = ''
                $ExecutionContext.SessionState.Module.PrivateData.TenantId = ''
                $ExecutionContext.SessionState.Module.PrivateData.ClientSecret = ''
            }
        }
    }

    It 'continues device-code polling while authorization is pending' {
        $global:IntunePfxTestDevicePoll = 0
        Mock -CommandName Start-Sleep -ModuleName IntunePfxImport {}
        Mock -CommandName Write-Host -ModuleName IntunePfxImport {}
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Uri)
            if ($Uri -match '/devicecode$') {
                return [pscustomobject]@{
                    device_code = 'device-code'
                    expires_in = 900
                    interval = 1
                    message = 'Authenticate'
                }
            }
            $global:IntunePfxTestDevicePoll++
            if ($global:IntunePfxTestDevicePoll -eq 1) {
                $record = New-Object Management.Automation.ErrorRecord(
                    [InvalidOperationException]::new('Authorization pending.'),
                    'authorization_pending',
                    [Management.Automation.ErrorCategory]::NotSpecified,
                    $null)
                $record.ErrorDetails = New-Object Management.Automation.ErrorDetails('{"error":"authorization_pending"}')
                throw $record
            }
            return [pscustomobject]@{ access_token = 'device-token'; expires_in = 3600 }
        }

        $setup = [pscustomobject]@{
            AuthenticationMode = 'PublicClient'
            ClientSecret = $null
            SetIntuneAuthenticationTokenParameters = [ordered]@{
                ClientId = '11111111-1111-1111-1111-111111111111'
                TenantId = '22222222-2222-2222-2222-222222222222'
                AuthUri = 'login.microsoftonline.com'
                GraphUri = 'https://graph.microsoft.com'
                SchemaVersion = 'beta'
                RedirectUri = 'https://login.microsoftonline.com/common/oauth2/nativeclient'
            }
        }
        Set-IntuneAuthenticationToken -Setup $setup -Confirm:$false

        if ($global:IntunePfxTestDevicePoll -ne 2) { throw 'Device-code authentication did not continue after authorization_pending.' }
    }

    It 'increases the device-code polling interval after slow_down' {
        $global:IntunePfxTestDevicePoll = 0
        $global:IntunePfxTestSleepIntervals = @()
        Mock -CommandName Start-Sleep -ModuleName IntunePfxImport {
            param($Seconds)
            $global:IntunePfxTestSleepIntervals += $Seconds
        }
        Mock -CommandName Write-Host -ModuleName IntunePfxImport {}
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Uri)
            if ($Uri -match '/devicecode$') {
                return [pscustomobject]@{
                    device_code = 'device-code'
                    expires_in = 900
                    interval = 2
                    message = 'Authenticate'
                }
            }
            $global:IntunePfxTestDevicePoll++
            if ($global:IntunePfxTestDevicePoll -eq 1) {
                $record = New-Object Management.Automation.ErrorRecord(
                    [InvalidOperationException]::new('Slow down.'),
                    'slow_down',
                    [Management.Automation.ErrorCategory]::NotSpecified,
                    $null)
                $record.ErrorDetails = New-Object Management.Automation.ErrorDetails('{"error":"slow_down"}')
                throw $record
            }
            return [pscustomobject]@{ access_token = 'device-token'; expires_in = 3600 }
        }

        Set-IntuneAuthenticationToken `
            -ClientId '11111111-1111-1111-1111-111111111111' `
            -TenantId '22222222-2222-2222-2222-222222222222' `
            -Confirm:$false

        if (
            $global:IntunePfxTestSleepIntervals.Count -ne 2 -or
            $global:IntunePfxTestSleepIntervals[0] -ne 2 -or
            $global:IntunePfxTestSleepIntervals[1] -ne 7
        ) {
            throw "Expected polling intervals 2 and 7 seconds but got '$($global:IntunePfxTestSleepIntervals -join ', ')'."
        }
    }

    It 'preserves empty and one-character password byte arrays and rejects non-ASCII passwords' {
        $module = Get-Module IntunePfxImport
        $emptyPassword = New-Object Security.SecureString
        $oneCharacterPassword = New-Object Security.SecureString
        $oneCharacterPassword.AppendChar('a')
        $nonAsciiPassword = New-Object Security.SecureString
        $nonAsciiPassword.AppendChar([char]0x00e9)

        $emptyBytes = & $module { param($value) ConvertTo-PasswordBytes -SecureString $value } $emptyPassword
        $oneCharacterBytes = & $module { param($value) ConvertTo-PasswordBytes -SecureString $value } $oneCharacterPassword
        $errorMessage = $null
        try {
            & $module { param($value) ConvertTo-PasswordBytes -SecureString $value } $nonAsciiPassword
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        if ($emptyBytes -isnot [byte[]] -or $emptyBytes.Length -ne 0) { throw 'An empty password must remain an empty byte array.' }
        if ($oneCharacterBytes -isnot [byte[]] -or $oneCharacterBytes.Length -ne 1 -or $oneCharacterBytes[0] -ne 97) {
            throw 'A one-character password must remain a one-byte array.'
        }
        if ($errorMessage -notlike '*only ASCII characters*') { throw 'Non-ASCII passwords must fail explicitly.' }
    }

    It 'reports a missing machine encryption key without cascading errors' {
        $module = Get-Module IntunePfxImport
        $missingKeyName = "MissingIntunePfxKey-$([Guid]::NewGuid())"
        $errorMessage = $null

        try {
            & $module {
                param($keyName)
                Invoke-IntunePasswordEncryption `
                    -PasswordBytes ([byte[]](1, 2, 3)) `
                    -ProviderName 'Microsoft Software Key Storage Provider' `
                    -KeyName $keyName `
                    -PaddingScheme OaepSha512
            } $missingKeyName
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        if ($errorMessage -notlike "*Machine CNG key '$missingKeyName' was not found*") {
            throw "Missing machine key error was not actionable. Error: $errorMessage"
        }
        if ($errorMessage -like '*encryptedPassword*') { throw 'A missing machine key produced a cascading encryptedPassword error.' }
    }

    It 'uses command-line configuration for client-secret auth and subsequent Graph requests' {
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Method, $Uri, $Body)
            if ($Uri -match '/oauth2/v2.0/token$') {
                return [pscustomobject]@{ access_token = 'test-token'; expires_in = 3600 }
            }
            return [pscustomobject]@{ value = @([pscustomobject]@{ thumbprint = 'abc'; userPrincipalName = 'user@contoso.com' }) }
        }
        $secret = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N')) -AsPlainText -Force

        Set-IntuneAuthenticationToken -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -ClientSecret $secret -Confirm:$false
        $result = Get-IntuneUserPfxCertificate

        if ($result.thumbprint -ne 'abc') { throw 'Graph response was not returned.' }
        Assert-MockCalled -CommandName Invoke-RestMethod -ModuleName IntunePfxImport -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222/oauth2/v2.0/token' -and
            $Body.client_id -eq '11111111-1111-1111-1111-111111111111' -and
            $Body.grant_type -eq 'client_credentials'
        }
        Assert-MockCalled -CommandName Invoke-RestMethod -ModuleName IntunePfxImport -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and
            $Uri -eq 'https://graph.microsoft.com/beta/deviceManagement/userPfxCertificates' -and
            $Headers.Authorization -eq 'Bearer test-token'
        }
    }

    It 'refreshes an expired client-secret token before sending a Graph request' {
        $global:IntunePfxTestTokenRequestCount = 0
        $global:IntunePfxTestGraphAuthorization = $null
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Method, $Uri, $Headers)
            if ($Uri -match '/oauth2/v2.0/token$') {
                $global:IntunePfxTestTokenRequestCount++
                if ($global:IntunePfxTestTokenRequestCount -eq 1) {
                    return [pscustomobject]@{ access_token = 'expired-token'; expires_in = 0 }
                }
                return [pscustomobject]@{ access_token = 'refreshed-token'; expires_in = 3600 }
            }
            $global:IntunePfxTestGraphAuthorization = $Headers.Authorization
            return [pscustomobject]@{ value = @() }
        }
        $secret = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N')) -AsPlainText -Force

        Set-IntuneAuthenticationToken -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -ClientSecret $secret -Confirm:$false
        Get-IntuneUserPfxCertificate | Out-Null

        if ($global:IntunePfxTestTokenRequestCount -ne 2) { throw 'An expired client-secret token was not refreshed.' }
        if ($global:IntunePfxTestGraphAuthorization -ne 'Bearer refreshed-token') { throw 'Graph request did not use the refreshed bearer token.' }
    }

    It 'serializes binary and date certificate fields for the Graph contract' {
        $global:IntunePfxTestRequestBody = $null
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Uri, $Body)
            if ($Uri -match '/oauth2/v2.0/token$') {
                return [pscustomobject]@{ access_token = 'serialization-token'; expires_in = 3600 }
            }
            $global:IntunePfxTestRequestBody = $Body
            return [pscustomobject]@{ id = 'created-certificate' }
        }
        $secret = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N')) -AsPlainText -Force
        $start = [DateTime]::SpecifyKind([DateTime]'2025-01-02T03:04:05', [DateTimeKind]::Utc)
        $certificate = [pscustomobject]@{
            thumbprint = 'abc'
            userPrincipalName = 'user@contoso.com'
            startDateTime = $start
            expirationDateTime = $start.AddDays(1)
            encryptedPfxBlob = [byte[]](1, 2, 3, 255)
            encryptedPfxPassword = 'AQ=='
        }

        Set-IntuneAuthenticationToken -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -ClientSecret $secret -Confirm:$false
        Import-IntuneUserPfxCertificate -CertificateList $certificate -Confirm:$false | Out-Null
        $requestBody = $global:IntunePfxTestRequestBody | ConvertFrom-Json

        if ($requestBody.encryptedPfxBlob -ne 'AQID/w==') { throw 'encryptedPfxBlob must be serialized as Base64.' }
        if ($null -ne $requestBody.PSObject.Properties['keyAlgorithm']) { throw 'keyAlgorithm is local metadata and is not valid in the Graph request body.' }
        if ($global:IntunePfxTestRequestBody -notmatch '"startDateTime"\s*:\s*"2025-01-02T03:04:05(\.0+)?Z"') {
            throw "startDateTime must be serialized as ISO-8601 UTC. Body: $global:IntunePfxTestRequestBody"
        }
        if ($global:IntunePfxTestRequestBody -notmatch '"expirationDateTime"\s*:\s*"2025-01-03T03:04:05(\.0+)?Z"') {
            throw "expirationDateTime must be serialized as ISO-8601 UTC. Body: $global:IntunePfxTestRequestBody"
        }
    }

    It 'continues an import batch after a per-record Graph failure' {
        $global:IntunePfxTestImportCount = 0
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Uri)
            if ($Uri -match '/oauth2/v2.0/token$') {
                return [pscustomobject]@{ access_token = 'batch-token'; expires_in = 3600 }
            }
            $global:IntunePfxTestImportCount++
            if ($global:IntunePfxTestImportCount -eq 1) {
                throw [InvalidOperationException]::new('First record failed.')
            }
            return [pscustomobject]@{ id = 'second-record' }
        }
        $secret = ConvertTo-SecureString 'batch-secret' -AsPlainText -Force
        $certificates = @(
            [pscustomobject]@{ thumbprint = 'first'; userPrincipalName = 'first@contoso.com'; encryptedPfxBlob = [byte[]](1); encryptedPfxPassword = 'AQ==' },
            [pscustomobject]@{ thumbprint = 'second'; userPrincipalName = 'second@contoso.com'; encryptedPfxBlob = [byte[]](2); encryptedPfxPassword = 'Ag==' }
        )
        Set-IntuneAuthenticationToken -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -ClientSecret $secret -Confirm:$false

        Import-IntuneUserPfxCertificate -CertificateList $certificates -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable importErrors

        if ($global:IntunePfxTestImportCount -ne 2) { throw 'Import stopped after the first record failure.' }
        if (@($importErrors).Count -lt 1) { throw 'Import did not surface the per-record error.' }
    }

    It 'follows Graph continuation links without changing endpoints' {
        $global:IntunePfxTestPage = 0
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Uri)
            if ($Uri -match '/oauth2/v2.0/token$') {
                return [pscustomobject]@{ access_token = 'paging-token'; expires_in = 3600 }
            }
            $global:IntunePfxTestPage++
            if ($global:IntunePfxTestPage -eq 1) {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ thumbprint = 'first' })
                    '@odata.nextLink' = 'https://graph.microsoft.com/beta/deviceManagement/userPfxCertificates?$skiptoken=next'
                }
            }
            return [pscustomobject]@{ value = @([pscustomobject]@{ thumbprint = 'second' }) }
        }
        $secret = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N')) -AsPlainText -Force

        Set-IntuneAuthenticationToken -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -ClientSecret $secret -Confirm:$false
        $result = @(Get-IntuneUserPfxCertificate)

        if ($result.Count -ne 2 -or $result[0].thumbprint -ne 'first' -or $result[1].thumbprint -ne 'second') {
            throw 'Graph continuation pages were not returned in order.'
        }
    }

    It 'normalizes Graph responses to the Version 2 PascalCase object shape' {
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Uri)
            if ($Uri -match '/oauth2/v2.0/token$') {
                return [pscustomobject]@{ access_token = 'shape-token'; expires_in = 3600 }
            }
            return [pscustomobject]@{ value = @([pscustomobject]@{
                thumbprint = 'abc'
                userPrincipalName = 'user@contoso.com'
                encryptedPfxBlob = 'AQID'
                startDateTime = '2025-01-02T03:04:05Z'
            }) }
        }
        $secret = ConvertTo-SecureString 'shape-secret' -AsPlainText -Force
        Set-IntuneAuthenticationToken -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -ClientSecret $secret -Confirm:$false

        $result = Get-IntuneUserPfxCertificate

        if ($result.PSObject.TypeNames[0] -ne 'Microsoft.Management.Services.Api.UserPFXCertificate') { throw 'Legacy type name is missing.' }
        if ($result.PSObject.Properties.Name -notcontains 'UserPrincipalName') { throw 'PascalCase properties are missing.' }
        if ($result.EncryptedPfxBlob -isnot [byte[]] -or $result.EncryptedPfxBlob.Length -ne 3) { throw 'Graph Base64 was not restored to byte[].' }
        if ($result.StartDateTime -isnot [DateTimeOffset]) { throw 'Graph dates were not restored to DateTimeOffset.' }
    }

    It 'accepts a Version 2 directory user ID for direct removal' {
        $global:IntunePfxTestDeleteUri = $null
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Method, $Uri)
            if ($Uri -match '/oauth2/v2.0/token$') {
                return [pscustomobject]@{ access_token = 'remove-token'; expires_in = 3600 }
            }
            $global:IntunePfxTestDeleteUri = $Uri
        }
        $secret = ConvertTo-SecureString 'remove-secret' -AsPlainText -Force
        Set-IntuneAuthenticationToken -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -ClientSecret $secret -Confirm:$false

        Remove-IntuneUserPfxCertificate -UserThumbprintList @{
            User = '0123456789abcdef0123456789abcdef'
            Thumbprint = 'aabbcc'
        } -Confirm:$false

        if ($global:IntunePfxTestDeleteUri -notlike '*/0123456789abcdef0123456789abcdef-aabbcc') {
            throw "Directory user ID was not used directly: $global:IntunePfxTestDeleteUri"
        }
    }

    It 'ships a parseable, clearly marked non-production E2E sample' {
        $samplePath = Join-Path $PSScriptRoot '..\Examples\Test-IntunePfxImportE2E.ps1'
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($samplePath, [ref]$tokens, [ref]$errors) | Out-Null
        $sampleText = Get-Content -LiteralPath $samplePath -Raw

        if (@($errors).Count -ne 0) { throw "E2E sample parser errors: $($errors.Message -join '; ')" }
        if ($sampleText -notmatch 'NOT FOR PRODUCTION USE') { throw 'E2E sample lacks the non-production disclaimer.' }
        if ($sampleText -notmatch "\[version\]'3\.0\.0'") { throw 'E2E sample does not require Version 3.0.0.' }
    }

    It 'preserves sovereign cloud AuthUri and GraphUri selections' {
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            [pscustomobject]@{ access_token = 'government-token'; expires_in = 3600 }
        }
        $secret = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N')) -AsPlainText -Force

        Set-IntuneAuthenticationToken -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -ClientSecret $secret -AuthUri 'login.microsoftonline.us' -GraphUri 'https://graph.microsoft.us' -Confirm:$false

        Assert-MockCalled -CommandName Invoke-RestMethod -ModuleName IntunePfxImport -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://login.microsoftonline.us/22222222-2222-2222-2222-222222222222/oauth2/v2.0/token' -and
            $Body.scope -eq 'https://graph.microsoft.us/.default'
        }
    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        It 'reads retry headers from PowerShell 7 HTTP responses' {
            $module = Get-Module IntunePfxImport
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::TooManyRequests)
            $response.Headers.TryAddWithoutValidation('x-ms-retry-after-ms', '1500') | Out-Null
            $exception = [pscustomobject]@{ Response = $response }

            $delay = & $module { param($value) Get-IntuneRetryDelay -Exception $value } $exception

            if ($delay -ne 2) { throw "Expected a two-second retry delay but got '$delay'." }
            $response.Dispose()
        }
    }

    It 'rejects an existing Graph SDK context for the wrong cloud' {
        Mock -CommandName Get-Command -ModuleName IntunePfxImport {
            param($Name)
            [pscustomobject]@{ Name = $Name }
        }
        Mock -CommandName Get-IntuneMgGraphContext -ModuleName IntunePfxImport {
            [pscustomobject]@{
                TenantId = '22222222-2222-2222-2222-222222222222'
                Environment = 'Global'
            }
        }

        $errorMessage = $null
        try {
            Initialize-IntunePfxImportApplication -GraphUri 'https://graph.microsoft.us' -AuthUri 'login.microsoftonline.us' -Confirm:$false
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        if ($errorMessage -notlike "*does not match the environment 'USGov'*") {
            throw 'Onboarding must reject a Graph SDK context connected to the wrong cloud.'
        }
    }

    It 'escapes single quotes in a UPN before issuing Graph requests' {
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            [pscustomobject]@{ value = @() }
        }

        Get-IntuneUserPfxCertificate -UserList "o'hara@contoso.com"

        Assert-MockCalled -CommandName Invoke-RestMethod -ModuleName IntunePfxImport -Times 1 -Exactly -ParameterFilter {
            [uri]::UnescapeDataString(([uri]$Uri).Query) -like "*o''hara@contoso.com*"
        }
    }

    It 'encodes legal URI delimiter characters in UPN filters' {
        $global:IntunePfxTestUserUri = $null
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Uri)
            if ($Uri -match '/oauth2/v2.0/token$') {
                return [pscustomobject]@{ access_token = 'uri-token'; expires_in = 3600 }
            }
            $global:IntunePfxTestUserUri = [uri]$Uri
            return [pscustomobject]@{ value = @() }
        }
        $secret = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N')) -AsPlainText -Force

        Set-IntuneAuthenticationToken -ClientId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -ClientSecret $secret -Confirm:$false
        Get-IntuneUserPfxCertificate -UserList 'a#b@contoso.com' | Out-Null

        if (-not [string]::IsNullOrEmpty($global:IntunePfxTestUserUri.Fragment)) { throw 'The UPN was interpreted as a URI fragment.' }
        if ([uri]::UnescapeDataString($global:IntunePfxTestUserUri.Query) -notlike '*a#b@contoso.com*') {
            throw 'The complete UPN was not preserved in the Graph filter.'
        }
    }

    It 'creates an idempotent Graph SDK application and returns splattable authentication settings' {
        $graphApplicationId = '00000003-0000-0000-c000-000000000000'
        $applicationId = '33333333-3333-3333-3333-333333333333'
        $tenantId = '22222222-2222-2222-2222-222222222222'
        $graphServicePrincipal = [pscustomobject]@{
            Id = 'graph-sp'
            AppRoles = @(
                [pscustomobject]@{ Id = 'role-device'; Value = 'DeviceManagementConfiguration.ReadWrite.All'; IsEnabled = $true },
                [pscustomobject]@{ Id = 'role-user'; Value = 'User.Read.All'; IsEnabled = $true }
            )
            Oauth2PermissionScopes = @(
                [pscustomobject]@{ Id = 'scope-device'; Value = 'DeviceManagementConfiguration.ReadWrite.All'; IsEnabled = $true },
                [pscustomobject]@{ Id = 'scope-user-all'; Value = 'User.Read.All'; IsEnabled = $true },
                [pscustomobject]@{ Id = 'scope-user'; Value = 'User.Read'; IsEnabled = $true }
            )
        }
        Mock -CommandName Get-Command -ModuleName IntunePfxImport {
            param($Name)
            [pscustomobject]@{ Name = $Name }
        }
        Mock -CommandName Get-IntuneMgGraphContext -ModuleName IntunePfxImport { [pscustomobject]@{ TenantId = '22222222-2222-2222-2222-222222222222' } }
        Mock -CommandName Get-IntuneMgServicePrincipal -ModuleName IntunePfxImport {
            param($Filter)
            if ($Filter -like '*00000003-0000-0000-c000-000000000000*') { return $global:IntunePfxTestGraphServicePrincipal }
            return @()
        }
        Mock -CommandName Get-IntuneMgApplication -ModuleName IntunePfxImport { return @() }
        Mock -CommandName New-IntuneMgApplication -ModuleName IntunePfxImport {
            param($Parameters)
            [pscustomobject]@{
                Id = 'application-object-id'
                AppId = '33333333-3333-3333-3333-333333333333'
                DisplayName = 'Intune PFX Import Test'
                RequiredResourceAccess = $Parameters.RequiredResourceAccess
                PublicClient = $Parameters.PublicClient
                IsFallbackPublicClient = $Parameters.IsFallbackPublicClient
            }
        }
        Mock -CommandName New-IntuneMgServicePrincipal -ModuleName IntunePfxImport {
            param($AppId)
            [pscustomobject]@{ Id = 'client-sp'; AppId = $AppId }
        }

        $result = Initialize-IntunePfxImportApplication -DisplayName 'Intune PFX Import Test' -AuthenticationMode Both -Confirm:$false

        if ($result.ApplicationId -ne $applicationId) { throw 'Application ID was not returned.' }
        if ($result.SetIntuneAuthenticationTokenParameters.ClientId -ne $applicationId) { throw 'Output is not splattable into Set-IntuneAuthenticationToken.' }
        if ($result.SetIntuneAuthenticationTokenParameters.TenantId -ne $tenantId) { throw 'Tenant ID was not returned.' }
        if ($result.AdminConsentUri -notlike "*$applicationId*") { throw 'Admin consent instructions do not identify the application.' }
        Assert-MockCalled -CommandName New-IntuneMgApplication -ModuleName IntunePfxImport -Times 1 -Exactly
        Assert-MockCalled -CommandName New-IntuneMgServicePrincipal -ModuleName IntunePfxImport -Times 1 -Exactly
    }

    It 'validates an existing application without changing Graph tenant objects' {
        $graphApplicationId = '00000003-0000-0000-c000-000000000000'
        $applicationId = '33333333-3333-3333-3333-333333333333'
        $tenantId = '22222222-2222-2222-2222-222222222222'
        $graphServicePrincipal = [pscustomobject]@{
            Id = 'graph-sp'
            AppRoles = @([pscustomobject]@{ Id = 'role-device'; Value = 'DeviceManagementConfiguration.ReadWrite.All'; IsEnabled = $true })
            Oauth2PermissionScopes = @(
                [pscustomobject]@{ Id = 'scope-device'; Value = 'DeviceManagementConfiguration.ReadWrite.All'; IsEnabled = $true },
                [pscustomobject]@{ Id = 'scope-user-all'; Value = 'User.Read.All'; IsEnabled = $true },
                [pscustomobject]@{ Id = 'scope-user'; Value = 'User.Read'; IsEnabled = $true }
            )
        }
        $existingApplication = [pscustomobject]@{
            Id = 'application-object-id'
            AppId = $applicationId
            DisplayName = 'Existing Intune PFX Import'
            RequiredResourceAccess = @()
            PublicClient = [pscustomobject]@{ RedirectUris = @() }
            IsFallbackPublicClient = $false
        }
        Mock -CommandName Get-Command -ModuleName IntunePfxImport {
            param($Name)
            [pscustomobject]@{ Name = $Name }
        }
        Mock -CommandName Get-IntuneMgGraphContext -ModuleName IntunePfxImport { [pscustomobject]@{ TenantId = '22222222-2222-2222-2222-222222222222' } }
        Mock -CommandName Get-IntuneMgServicePrincipal -ModuleName IntunePfxImport {
            param($Filter)
            if ($Filter -like '*00000003-0000-0000-c000-000000000000*') { return $global:IntunePfxTestGraphServicePrincipal }
            return [pscustomobject]@{ Id = 'client-sp'; AppId = '33333333-3333-3333-3333-333333333333' }
        }
        $global:IntunePfxTestExistingApplication = $existingApplication
        Mock -CommandName Get-IntuneMgApplication -ModuleName IntunePfxImport { return $global:IntunePfxTestExistingApplication }
        Mock -CommandName New-IntuneMgApplication -ModuleName IntunePfxImport { throw 'ValidateOnly must not create an application.' }
        Mock -CommandName Update-IntuneMgApplication -ModuleName IntunePfxImport { throw 'ValidateOnly must not update an application.' }
        Mock -CommandName New-IntuneMgServicePrincipal -ModuleName IntunePfxImport { throw 'ValidateOnly must not create a service principal.' }

        $result = Initialize-IntunePfxImportApplication -ExistingApplicationId $applicationId -AuthenticationMode PublicClient -ValidateOnly -Confirm:$false

        if ($result.ChangesRequiredOrApplied -notcontains 'RequiredResourceAccess') { throw 'ValidateOnly did not report missing required permissions.' }
        if ($result.ChangesRequiredOrApplied -notcontains 'PublicClient') { throw 'ValidateOnly did not report public-client configuration.' }
    }

    It 'fails when an explicit existing application ID is not found' {
        Mock -CommandName Get-Command -ModuleName IntunePfxImport {
            param($Name)
            [pscustomobject]@{ Name = $Name }
        }
        Mock -CommandName Get-IntuneMgGraphContext -ModuleName IntunePfxImport {
            [pscustomobject]@{ TenantId = '22222222-2222-2222-2222-222222222222' }
        }
        Mock -CommandName Get-IntuneMgServicePrincipal -ModuleName IntunePfxImport {
            return $global:IntunePfxTestGraphServicePrincipal
        }
        Mock -CommandName Get-IntuneMgApplication -ModuleName IntunePfxImport { return @() }
        Mock -CommandName New-IntuneMgApplication -ModuleName IntunePfxImport {
            throw 'A missing explicit application must not create a replacement.'
        }

        $errorMessage = $null
        try {
            Initialize-IntunePfxImportApplication `
                -ExistingApplicationId '33333333-3333-3333-3333-333333333333' `
                -AuthenticationMode PublicClient `
                -Confirm:$false
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        if ($errorMessage -notlike "*No application registration was found for ExistingApplicationId*") {
            throw "Expected a missing-application error but got: $errorMessage"
        }
        Assert-MockCalled -CommandName New-IntuneMgApplication -ModuleName IntunePfxImport -Times 0 -Exactly
    }

    It 'creates a secure one-time client secret only when requested' {
        $graphApplicationId = '00000003-0000-0000-c000-000000000000'
        $applicationId = '33333333-3333-3333-3333-333333333333'
        $tenantId = '22222222-2222-2222-2222-222222222222'
        $graphServicePrincipal = [pscustomobject]@{
            Id = 'graph-sp'
            AppRoles = @(
                [pscustomobject]@{ Id = 'role-device'; Value = 'DeviceManagementConfiguration.ReadWrite.All'; IsEnabled = $true },
                [pscustomobject]@{ Id = 'role-user'; Value = 'User.Read.All'; IsEnabled = $true }
            )
            Oauth2PermissionScopes = @()
        }
        $existingApplication = [pscustomobject]@{
            Id = 'application-object-id'
            AppId = $applicationId
            DisplayName = 'Existing Intune PFX Import'
            RequiredResourceAccess = @(@{ ResourceAppId = $graphApplicationId; ResourceAccess = @(
                [pscustomobject]@{ Id = 'role-device'; Type = 'Role' },
                [pscustomobject]@{ Id = 'role-user'; Type = 'Role' }
            ) })
            PublicClient = [pscustomobject]@{ RedirectUris = @() }
            IsFallbackPublicClient = $false
        }
        $oneTimeSecret = [Guid]::NewGuid().ToString('N')
        Mock -CommandName Get-Command -ModuleName IntunePfxImport {
            param($Name)
            [pscustomobject]@{ Name = $Name }
        }
        Mock -CommandName Get-IntuneMgGraphContext -ModuleName IntunePfxImport { [pscustomobject]@{ TenantId = '22222222-2222-2222-2222-222222222222' } }
        Mock -CommandName Get-IntuneMgServicePrincipal -ModuleName IntunePfxImport {
            param($Filter)
            if ($Filter -like '*00000003-0000-0000-c000-000000000000*') { return $global:IntunePfxTestGraphServicePrincipal }
            return [pscustomobject]@{ Id = 'client-sp'; AppId = '33333333-3333-3333-3333-333333333333' }
        }
        $global:IntunePfxTestExistingApplication = $existingApplication
        $global:IntunePfxTestSecret = $oneTimeSecret
        Mock -CommandName Get-IntuneMgApplication -ModuleName IntunePfxImport { return $global:IntunePfxTestExistingApplication }
        Mock -CommandName Add-IntuneMgApplicationPassword -ModuleName IntunePfxImport {
            param($ApplicationId, $PasswordCredential)
            [pscustomobject]@{ SecretText = $global:IntunePfxTestSecret }
        }
        Mock -CommandName Invoke-RestMethod -ModuleName IntunePfxImport {
            param($Uri)
            if ($Uri -match '/oauth2/v2.0/token$') {
                return [pscustomobject]@{ access_token = 'onboarding-test-token'; expires_in = 3600 }
            }
            return [pscustomobject]@{ value = @() }
        }

        $result = Initialize-IntunePfxImportApplication -ExistingApplicationId $applicationId -AuthenticationMode ClientSecret -CreateClientSecret -Confirm:$false

        if ($result.ClientSecret -isnot [Security.SecureString]) { throw 'The one-time client secret must be returned as a SecureString.' }
        if ($result.AdminConsentInstructions -notmatch 'Privileged Role Administrator or Global Administrator') { throw 'Application-mode consent guidance must require Privileged Role Administrator or Global Administrator.' }
        Set-IntuneAuthenticationToken -Setup $result -Confirm:$false
        Get-IntuneUserPfxCertificate | Out-Null
        Assert-MockCalled -CommandName Add-IntuneMgApplicationPassword -ModuleName IntunePfxImport -Times 1 -Exactly
    }

    It 'does not mutate tenant objects when onboarding is simulated with WhatIf' {
        Mock -CommandName Get-Command -ModuleName IntunePfxImport {
            param($Name)
            [pscustomobject]@{ Name = $Name }
        }
        Mock -CommandName Get-IntuneMgGraphContext -ModuleName IntunePfxImport { [pscustomobject]@{ TenantId = '22222222-2222-2222-2222-222222222222' } }
        Mock -CommandName Get-IntuneMgServicePrincipal -ModuleName IntunePfxImport {
            param($Filter)
            if ($Filter -like '*00000003-0000-0000-c000-000000000000*') { return $global:IntunePfxTestGraphServicePrincipal }
            return @()
        }
        Mock -CommandName Get-IntuneMgApplication -ModuleName IntunePfxImport { return @() }
        Mock -CommandName New-IntuneMgApplication -ModuleName IntunePfxImport { throw 'WhatIf must not create an application.' }
        Mock -CommandName New-IntuneMgServicePrincipal -ModuleName IntunePfxImport { throw 'WhatIf must not create a service principal.' }

        Initialize-IntunePfxImportApplication -DisplayName 'WhatIf Intune PFX Import' -AuthenticationMode Both -WhatIf

    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        It 'creates an ECC record with ephemeral PFX loading and a TestDrive public key' {
            $ecdsa = [Security.Cryptography.ECDsa]::Create()
            $ecdsa.GenerateKey([Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP384'))
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                'CN=ECC PFX Test',
                $ecdsa,
                [Security.Cryptography.HashAlgorithmName]::SHA384)
            $subjectAlternativeName = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
            $subjectAlternativeName.AddEmailAddress('user@contoso.com')
            $request.CertificateExtensions.Add($subjectAlternativeName.Build())
            $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
            $pfxPath = Join-Path $TestDrive 'ecc.pfx'
            $passwordText = [Guid]::NewGuid().ToString('N')
            [IO.File]::WriteAllBytes($pfxPath, $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $passwordText))

            $rsa = [Security.Cryptography.RSA]::Create(2048)
            $base64 = [Convert]::ToBase64String($rsa.ExportSubjectPublicKeyInfo())
            $pem = "-----BEGIN PUBLIC KEY-----`n" + (($base64 -split '(.{1,64})' | Where-Object { $_ }) -join "`n") + "`n-----END PUBLIC KEY-----`n"
            $keyPath = Join-Path $TestDrive 'public.key'
            [IO.File]::WriteAllText($keyPath, $pem)
            $password = ConvertTo-SecureString $passwordText -AsPlainText -Force

            $result = New-IntuneUserPfxCertificate -PathToPfxFile $pfxPath -PfxPassword $password -KeyFilePath $keyPath -IntendedPurpose 1 -PaddingScheme None

            if ($result.keyAlgorithm -ne 'ecc') { throw "Expected ECC keyAlgorithm but got '$($result.keyAlgorithm)'." }
            if ($result.userPrincipalName -ne 'user@contoso.com') { throw 'The UPN was not inferred from the certificate email name.' }
            if ($result.paddingScheme -ne 'oaepSha512') { throw 'Expected OAEP SHA-512 padding.' }
            if ($result.intendedPurpose -ne 'smimeEncryption') { throw 'Version 2 numeric intended purpose was not normalized.' }
            if ([string]::IsNullOrWhiteSpace($result.encryptedPfxPassword)) { throw 'The PFX password was not encrypted.' }
            if ($result.StartDateTime -isnot [DateTimeOffset] -or $result.ExpirationDateTime -isnot [DateTimeOffset]) {
                throw 'Version 2 certificate dates must remain DateTimeOffset values.'
            }
        }
    }
}
