#Requires -Version 3.0
<#
    .SYNOPSIS
        Iterates through all or a subset of sites via the SentinelOne API and decommissionss inactive duplicate agents.
    .Example
        .\S1-Remove-Duplicate-Agents.ps1 -SiteFilter site1, site2
    .Author
        Anthony Kolka
#>
[cmdletbinding(SupportsShouldProcess)]
param(
    #S1 API Key
    [Parameter(Mandatory=$false)]
        [string]
        $ApiKey,
    #One or more site names to filter site list 
    [Parameter(Mandatory=$false)]
        [string[]]
        $SiteFilter,
    [Parameter(Mandatory=$false)]
        [switch]
        $WriteLog = $false,
    [Parameter(Mandatory=$false)]
        [string]
        $LogPath = './'
)
if(!$ApiKey){
    $ApiKey = Read-Host -Prompt 'Input SentinelOne API Key'
}
if($WriteLog){
    $LogPath = Resolve-Path $LogPath
    if(!(Test-Path $LogPath)) {
        Write-Error "Could not open $($LogPath)"
        exit
    }
    $LogPath += "\SentinelOne_Deduplication_$(Get-Date -Format "yyyy-MM-dd_HH-mm").log"
}
$decommissions = 0
$decomObj = @{
    filter = @{
        ids = ""
    } 
}
$errors = 0
$warnings = 0

function ConvertTo-StringData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [HashTable[]]$HashTable
    )
    process {
        foreach ($item in $HashTable) {
            foreach ($entry in $item.GetEnumerator()) {
                "{0}={1}" -f $entry.Key, $entry.Value
            }
        }
    }
}

function Invoke-S1APIRequest(){
    [CmdletBinding()]
    Param(
        #URL path portion
        [Parameter(Mandatory=$true, Position = 0)]
            [string]
            $UrlSlug,
        # request body to be encoded as JSON
        [Parameter(Mandatory=$false, Position = 1)]
            $Data,
        [Parameter(Mandatory=$false, Position = 2)]
            [string]
            $Method = 'GET'
    )
    #$ApiKey defined in script params
    $requestParams = @{
        Uri = "https://usea1-ninjaone.sentinelone.net/web/api/v2.1/$UrlSlug"
        Method = $Method
        Headers = @{
            Authorization = "ApiToken $($ApiKey.Trim())"
        }
        ContentType = "application/json"
    }
    if($Data){
        $requestParams.Body = ConvertTo-Json $Data
    }
    Write-Debug "Invoking API request with params $(ConvertTo-StringData($requestParams))"
    try {
        $response = Invoke-RestMethod @requestParams
    } catch {
        throw $_
    }
    return $response
}

function Write-ToLog
{
    [CmdletBinding()]
    param (
        #Path to log File
        [Parameter(Mandatory=$true)]
            [string]
            $File,
        #line(s) to be written
        [Parameter(Mandatory=$true)]
            [string]
            $Message
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $File -Value "$ts| $Message" -Force -WhatIf:$false
}

$filterParam = ""
if($SiteFilter){
    if ($SiteFilter -is [array]) {
        $SiteFilter = $SiteFilter -join ","
    }
    $SiteFilter = $SiteFilter -replace "\s", ""
    Write-Debug "Will filter sites using $($SiteFilter)"
    $filterParam = "&name__contains=$SiteFilter"
}

if($WriteLog){
    Write-ToLog -File $LogPath -Message "Process started"
}

$collectMoreSites = $true
$cursor = ""
while ($collectMoreSites) {
    try{
        $siteRequest = Invoke-S1APIRequest "sites?sortBy=name&state=active$filterParam$cursor"
    }catch{
        Write-Error "Error collecting sites from API. $_"
        exit 1
    }
    foreach($site in $siteRequest.Data.sites){
        $msg = "Processing Site $($site.name)"
        Write-Host $msg
        if($WriteLog){
            Write-ToLog -File $LogPath -Message $msg
        }
        $agentCursor = ""
        $collectMoreAgents = $true
        $agentCounts = @{}
        [System.Collections.ArrayList]$agents = @()
        while($collectMoreAgents){
            try{
                $agentRequest = Invoke-S1APIRequest "agents?isDecommissioned=False&siteIds=$($site.id)$agentCursor"
            }catch{
                Write-Error "Error collecting agents from API. $_"
                if($WriteLog){
                    Write-ToLog -File $LogPath -Message $_
                }
                exit 2
            }
            foreach($agent in $agentRequest.Data){
                $agents.Add($agent) | Out-Null
                if($agent.computerName -in $agentCounts.Keys){
                    $agentCounts[$agent.computerName]++
                }else{
                    $agentCounts[$agent.computerName] = 1
                }
            }
            if($agentRequest.pagination.nextCursor){
                $agentCursor = "&cursor=$($agentRequest.pagination.nextCursor)"
            }else{
                $collectMoreAgents = $false
            }
        }
        #process computers with more than one agent definition
        foreach($computerName in $agentCounts.Keys) {
            if($agentCounts[$computerName] -gt 1){
                $msg = "Computer name $computerName has $($agentCounts[$computerName]) agents"
                Write-Host $msg
                if($WriteLog){
                    Write-ToLog -File $LogPath -Message $msg
                }
                $dupes = $agents | Where-Object { $_.computerName -eq $computerName } | Sort-Object -Property updatedAt | Select-Object -SkipLast 1
                foreach($dupe in $dupes){
                    #decom agents
                    if($dupe.isActive){
                        $msg = "Warning: Active agent selected for decom $($dupe.uuid)"
                        Write-Host $msg
                        if($WriteLog){
                            Write-ToLog -File $LogPath -Message $msg
                            $msg = Out-String -InputObject $dupe
                            Write-ToLog -File $LogPath -Message $msg
                        }
                        $warnings++
                        continue
                    }
                    $decommissions++
                    if($WhatIfPreference){
                        $msg = "Decommission agent $($dupe.id)"
                        Write-Host $msg
                        $dupe
                        if($WriteLog){
                            Write-ToLog -File $LogPath -Message $msg
                            $msg = Out-String -InputObject $dupe
                            Write-ToLog -File $LogPath -Message $msg
                        }
                    }else{
                        $msg = "Decommission agent $($dupe.id)"
                        Write-Host $msg
                        if($WriteLog){
                            Write-ToLog -File $LogPath -Message $msg
                        }
                        $decomObj.filter.ids = $dupe.id
                        try{
                            Invoke-S1APIRequest -UrlSlug "agents/actions/decommission" -Data $decomObj -Method "POST"
                        }catch{
                            Write-Error "Error decomissioning agent $_"
                            if($WriteLog){
                                Write-ToLog -File $LogPath -Message $_
                            }
                            $decommissions--
                            $errors++
                        }
                    }
                }
            }
        }
    }
    if($siteRequest.pagination.nextCursor){
        $cursor = "&cursor=$($siteRequest.pagination.nextCursor)"
    }else{
        $collectMoreSites = $false
    }
}
$msg = "Decommissioned $decommissions agents with $errors errors and $warnings warnings"
if($WhatIfPreference){
    $msg = "What If: $msg"
}
Write-Host $msg
if($WriteLog){
    Write-ToLog -File $LogPath -Message $msg
}
