using namespace System.Net

function Invoke-ListDomainHealth {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        Tenant.DomainAnalyser.Read
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    Write-LogMessage -headers $Headers -API $APIName -message 'Accessed this API' -Sev 'Debug'

    Import-Module DNSHealth

    try {
        $ConfigTable = Get-CippTable -tablename Config
        $Filter = "PartitionKey eq 'Domains' and RowKey eq 'Domains'"
        $Config = Get-CIPPAzDataTableEntity @ConfigTable -Filter $Filter

        $ValidResolvers = @('Google', 'CloudFlare', 'Quad9')
        if ($ValidResolvers -contains $Config.Resolver) {
            $Resolver = $Config.Resolver
        } else {
            $Resolver = 'Google'
            $Config = @{
                PartitionKey = 'Domains'
                RowKey       = 'Domains'
                Resolver     = $Resolver
            }
            Add-CIPPAzDataTableEntity @ConfigTable -Entity $Config -Force
        }
    } catch {
        $Resolver = 'Google'
    }

    Set-DnsResolver -Resolver $Resolver

    $UserRoles = Get-CIPPAccessRole -Request $Request

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    Write-LogMessage -headers $Headers -API $APIName -message 'Accessed this API' -Sev 'Debug'



    $StatusCode = [HttpStatusCode]::OK
    try {
        if ($Request.Query.Action) {
            if ($Request.Query.Domain -match '^(((?!-))(xn--|_{1,1})?[a-z0-9-]{0,61}[a-z0-9]{1,1}\.)*(xn--)?([a-z0-9][a-z0-9\-]{0,60}|[a-z0-9-]{1,30}\.[a-z]{2,})$') {
                $DomainTable = Get-CIPPTable -Table 'Domains'
                $Filter = "RowKey eq '{0}'" -f $Request.Query.Domain
                $DomainInfo = Get-CIPPAzDataTableEntity @DomainTable -Filter $Filter
                switch ($Request.Query.Action) {
                    'ListDomainInfo' {
                        $Body = $DomainInfo
                    }
                    'GetDkimSelectors' {
                        $Body = ($DomainInfo.DkimSelectors | ConvertFrom-Json) -join ','
                    }
                    'ReadSpfRecord' {
                        $SpfQuery = @{
                            Domain = $Request.Query.Domain
                        }

                        if ($Request.Query.ExpectedInclude) {
                            $SpfQuery.ExpectedInclude = $Request.Query.ExpectedInclude
                        }

                        if ($Request.Query.Record) {
                            $SpfQuery.Record = $Request.Query.Record
                        }

                        $Body = Read-SpfRecord @SpfQuery
                    }
                    'ReadDmarcPolicy' {
                        $Body = Read-DmarcPolicy -Domain $Request.Query.Domain
                    }
                    'ReadDkimRecord' {
                        $DkimQuery = @{
                            Domain                       = $Request.Query.Domain
                            FallbackToMicrosoftSelectors = $true
                        }
                        if ($Request.Query.Selector) {
                            $DkimQuery.Selectors = ($Request.Query.Selector).trim() -split '\s*,\s*'

                            if ('admin' -in $UserRoles -or 'editor' -in $UserRoles) {
                                $DkimSelectors = [string]($DkimQuery.Selectors | ConvertTo-Json -Compress)
                                if ($DomainInfo) {
                                    $DomainInfo.DkimSelectors = $DkimSelectors
                                } else {
                                    $DomainInfo = @{
                                        'RowKey'         = $Request.Query.Domain
                                        'PartitionKey'   = 'ManualEntry'
                                        'TenantId'       = 'NoTenant'
                                        'MailProviders'  = ''
                                        'TenantDetails'  = ''
                                        'DomainAnalyser' = ''
                                        'DkimSelectors'  = $DkimSelectors
                                    }
                                }
                                Write-Host $DomainInfo
                                Add-CIPPAzDataTableEntity @DomainTable -Entity $DomainInfo -Force
                            }
                        } elseif (![string]::IsNullOrEmpty($DomainInfo.DkimSelectors)) {
                            $DkimQuery.Selectors = [System.Collections.Generic.List[string]]($DomainInfo.DkimSelectors | ConvertFrom-Json)
                        }
                        $Body = Read-DkimRecord @DkimQuery

                    }
                    'ReadMXRecord' {
                        $Body = Read-MXRecord -Domain $Request.Query.Domain
                    }
                    'TestDNSSEC' {
                        $Body = Test-DNSSEC -Domain $Request.Query.Domain
                    }
                    'ReadWhoisRecord' {
                        $Body = Read-WhoisRecord -Query $Request.Query.Domain
                    }
                    'ReadNSRecord' {
                        $Body = Read-NSRecord -Domain $Request.Query.Domain
                    }
                    'TestHttpsCertificate' {
                        $HttpsQuery = @{
                            Domain = $Request.Query.Domain
                        }
                        if ($Request.Query.Subdomains) {
                            $HttpsQuery.Subdomains = ($Request.Query.Subdomains).trim() -split '\s*,\s*'
                        } else {
                            $HttpsQuery.Subdomains = 'www'
                        }

                        $Body = Test-HttpsCertificate @HttpsQuery
                    }
                    'TestMtaSts' {
                        $HttpsQuery = @{
                            Domain = $Request.Query.Domain
                        }
                        $Body = Test-MtaSts @HttpsQuery
                    }
                }
            } else {
                $body = [pscustomobject]@{'Results' = "Domain: $($Request.Query.Domain) is invalid" }
            }
        }
    } catch {
        Write-LogMessage -API $APINAME -tenant $($name) -headers $Request.Headers -message "DNS Helper API failed. $($_.Exception.Message)" -Sev 'Error'
        $body = [pscustomobject]@{'Results' = "Failed. $($_.Exception.Message)" }
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    # Associate values to output bindings by calling 'Push-OutputBinding'.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $body
        })

}
