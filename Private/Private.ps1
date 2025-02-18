function Add-Include {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [object[]]$Object,
        [System.Object]$Inputs,
        [System.Collections.Hashtable]$Index,
        [string]$Command
    )
    if ($Inputs.Include) {
        if (!$Object.id -and $Object -isnot [PSCustomObject]) {
            # Create array of [PSCustomObject] with 'id' property
            $Object = @($Object).foreach{ ,[PSCustomObject]@{ id = $_ }}
        } else {
            $Detailed = $true
        }
        if ($Index) {
            $Index.GetEnumerator().foreach{
                # Use 'Index' for 'Include' name and command to gather value(s) and append to output
                if ($Inputs.Include -contains $_.Key) {
                    if ($_.Key -eq 'members') {
                        foreach ($i in $Object) {
                            # Add 'members' by object
                            $SetParam = @{
                                Object = $i
                                Name = $_.Key
                                Value = if ($Detailed -eq $true) {
                                    & "$($_.Value)" -Id $i.id -Detailed -All -EA 0
                                } else {
                                    & "$($_.Value)" -Id $i.id -All -EA 0
                                }
                            }
                            Set-Property @SetParam
                        }
                    } else {
                        foreach ($i in (& "$($_.Value)" -Id $Object.id)) {
                            $SetParam = @{
                                Object = if ($i.policy_id) {
                                    $Object | Where-Object { $_.id -eq $i.policy_id }
                                } else {
                                    $Object | Where-Object { $_.id -eq $i.id }
                                }
                                Name = $_.Key
                                Value = $i
                            }
                            Set-Property @SetParam
                        }
                    }
                }
            }
        } elseif ($Command) {
            foreach ($i in (& $Command -Id $Object.id)) {
                @($Inputs.Include).foreach{
                    # Append all properties from 'Include'
                    $SetParam = @{
                        Object = if ($i.device_id) {
                            $Object | Where-Object { $_.id -eq $i.device_id }
                        } else {
                            $Object | Where-Object { $_.id -eq $i.id }
                        }
                        Name = $_
                        Value = $i.$_
                    }
                    Set-Property @SetParam
                }
            }
        }
    }
    return $Object
}
function Assert-Extension {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path,[string]$Extension)
    process {
        # Verify that 'Path' has a file extension matching 'Extension'
        if ($Path -and $Extension) {
            if ([System.IO.Path]::GetExtension($Path) -eq ".$Extension") {
                $Path
            } else {
                $Path,$Extension -join '.'
            }
        }
    }
}
function Build-Content {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([System.Object]$Format,[System.Object]$Inputs)
    begin {
        function Build-Body ($Format,$Inputs) {
            $Body = @{}
            $Inputs.GetEnumerator().Where({ $Format.Body.Values -match $_.Key }).foreach{
                if ($_.Key -eq 'raw_array') {
                    $RawArray = @($_.Value)
                } else {
                    $Field = ($_.Key).ToLower()
                    $Value = if ($_.Value -is [string] -and $_.Value -eq 'null') {
                        # Convert [string] values of 'null' to null values
                        $null
                    } elseif ($_.Value -is [array]) {
                        # Convert [string] values of 'null' to null values
                        ,($_.Value).foreach{ if ($_ -is [string] -and $_ -eq 'null') { $null } else { $_ } }
                    } else {
                        $_.Value
                    }
                    if ($Field -eq 'body' -and ($Format.Body.root | Measure-Object).Count -eq 1) {
                        # Add 'body' value as [System.Net.Http.ByteArrayContent] when it's the only property
                        $FullFilePath = $Script:Falcon.Api.Path($_.Value)
                        $ByteStream = if ($PSVersionTable.PSVersion.Major -ge 6) {
                            Get-Content $FullFilePath -AsByteStream
                        } else {
                            Get-Content $FullFilePath -Encoding Byte -Raw
                        }
                        $ByteArray = [System.Net.Http.ByteArrayContent]::New($ByteStream)
                        $ByteArray.Headers.Add('Content-Type',$Headers.ContentType)
                    } else {
                        if (!$Body) { $Body = @{} }
                        if (($Value -is [array] -or $Value -is [string]) -and $Value |
                        Get-Member -MemberType Method | Where-Object { $_.Name -eq 'Normalize' }) {
                            # Normalize values to avoid Json conversion errors when 'Get-Content' was used
                            if ($Value -is [array]) {
                                $Value = [array] ($Value).Normalize()
                            } elseif ($Value -is [string]) {
                                $Value = ($Value).Normalize()
                            }
                        }
                        $Format.Body.GetEnumerator().Where({ $_.Value -eq $Field }).foreach{
                            if ($_.Key -eq 'root') {
                                # Add key/value pair directly to 'Body'
                                $Body.Add($Field,$Value)
                            } else {
                                # Create parent object and add key/value pair
                                if (!$Parents) { $Parents = @{} }
                                if (!$Parents.($_.Key)) { $Parents[$_.Key] = @{} }
                                $Parents.($_.Key).Add($Field,$Value)
                            }
                        }
                    }
                }
            }
            if ($ByteArray) {
                # Return 'ByteArray' object
                $ByteArray
            } elseif ($RawArray) {
                # Return 'RawArray' object and force [array]
                ,$RawArray
            } else {
                # Add parents as arrays in 'Body' and return 'Body' object
                if ($Parents) { $Parents.GetEnumerator().foreach{ $Body[$_.Key] = @($_.Value) }}
                if (($Body.Keys | Measure-Object).Count -gt 0) { $Body }
            }
        }
        function Build-Formdata ($Format,$Inputs) {
            $Formdata = @{}
            $Inputs.GetEnumerator().Where({ $Format.Formdata -contains $_.Key }).foreach{
                $Formdata[($_.Key).ToLower()] = if ($_.Key -eq 'content') {
                    $Content = try {
                        # Collect file content as a string
                        [string](Get-Content ($Script:Falcon.Api.Path($_.Value)) -Raw -EA 0)
                    } catch {
                        $null
                    }
                    # Supply original value if no file content is gathered
                    if ($Content) { $Content } else { $_.Value }
                } else {
                    $_.Value
                }
            }
            # Return 'Formdata' object
            if (($Formdata.Keys | Measure-Object).Count -gt 0) { $Formdata }
        }
        function Build-Query ($Format,$Inputs) {
            # Regex pattern for matching 'last [int] days/hours'
            [regex]$Relative = '([Ll]ast (?<Int>\d{1,}) ([Dd]ay[s]?|[Hh]our[s]?))'
            [array]$Query = foreach ($Field in $Format.Query.Where({ $Inputs.Keys -contains $_ })) {
                foreach ($Value in ($Inputs.GetEnumerator().Where({ $_.Key -eq $Field }).Value)) {
                    if ($Field -eq 'filter' -and $Value -match $Relative) {
                        # Convert 'last [int] days/hours' to Rfc3339
                        @($Value | Select-String $Relative -AllMatches).foreach{
                            foreach ($Match in $_.Matches.Value) {
                                [int]$Int = $Match -replace $Relative,'${Int}'
                                $Int = if ($Match -match 'day') { $Int * -24 } else { $Int * -1 }
                                $Value = $Value -replace $Match,(Convert-Rfc3339 $Int)
                            }
                        }
                    }
                    # Output array of strings to append to 'Path' and HTML-encode '+'
                    ,"$($Field)=$($Value -replace '\+','%2B')"
                }
            }
            # Return 'Query' array
            if ($Query) { $Query }
        }
    }
    process {
        if ($Inputs) {
            $Content = @{}
            @('Body','Formdata','Outfile','Query').foreach{
                if ($Format.$_) {
                    $Value = if ($_ -eq 'Outfile') {
                        # Get absolute path for 'OutFile'
                        $Outfile = $Inputs.GetEnumerator().Where({ $Format.Outfile -eq $_.Key }).Value
                        if ($Outfile) { $Script:Falcon.Api.Path($Outfile) }
                    } else {
                        # Get value(s) from each 'Build' function
                        & "Build-$_" -Format $Format -Inputs $Inputs
                    }
                    if ($Value) { $Content[$_] = $Value }
                }
            }
        }
    }
    end {
         # Return 'Content' table
        if (($Content.Keys | Measure-Object).Count -gt 0) { $Content }
    }
}
function Confirm-Parameter {
    [CmdletBinding()]
    [OutputType([boolean])]
    param(
        [Parameter(Mandatory)]
        [System.Object]$Object,
        [Parameter(Mandatory)]
        [string]$Command,
        [Parameter(Mandatory)]
        [string]$Endpoint,
        [string[]]$Required,
        [string[]]$Allowed,
        [string[]]$Content,
        [string[]]$Pattern,
        [System.Collections.Hashtable]$Format
    )
    begin {
        function Get-ValidPattern ([string]$Command,[string]$Endpoint,[string]$Parameter) {
            # Return 'ValidPattern' from parameter of a given command
            (Get-Command $Command).ParameterSets.Where({ $_.Name -eq $Endpoint }).Parameters.Where({
                $_.Name -eq $Parameter -or $_.Aliases -contains $Parameter }).Attributes.RegexPattern
        }
        function Get-ValidValues ([string]$Command,[string]$Endpoint,[string]$Parameter) {
            # Return 'ValidValues' from parameter of a given command
            (Get-Command $Command).ParameterSets.Where({ $_.Name -eq $Endpoint }).Parameters.Where({
                $_.Name -eq $Parameter -or $_.Aliases -contains $Parameter }).Attributes.ValidValues
        }
        # Create object string
        $ObjectString = ConvertTo-Json $Object -Depth 32 -Compress
    }
    process {
        if ($Object -is [System.Collections.Hashtable]) {
            @($Required).foreach{
                # Verify object contains required fields
                if ($Object.Keys -notcontains $_) { throw "Missing '$_'. $ObjectString" } else { $true }
            }
            if ($Allowed) {
                @($Object.Keys).foreach{
                    # Error if field is not in allowed list
                    if ($Allowed -notcontains $_) { throw "Unexpected '$_'. $ObjectString" } else { $true }
                }
            }
        } elseif ($Object -is [PSCustomObject]) {
            @($Required).foreach{
                # Verify object contains required fields
                if ($Object.PSObject.Members.Where({ $_.MemberType -eq 'NoteProperty' }).Name -notcontains $_) {
                    throw "Missing '$_'. $ObjectString"
                } else {
                    $true
                }
            }
            if ($Allowed) {
                @($Object.PSObject.Members.Where({ $_.MemberType -eq 'NoteProperty' }).Name).foreach{
                    # Error if field is not in allowed list
                    if ($Allowed -notcontains $_) { throw "Unexpected '$_'. $ObjectString" } else { $true }
                }
            }
        }
        @($Content).foreach{
            # Match property name with parameter name
            [string]$Parameter = if ($Format -and $Format.$_) { $Format.$_ } else { $_ }
            if ($Object.$_) {
                # Verify that 'ValidValues' contains provided value
                [string[]]$ValidValues = Get-ValidValues $Command $Endpoint $Parameter
                if ($Object.$_ -is [array]) {
                    foreach ($Item in $Object.$_) {
                        if ($ValidValues -notcontains $Item) { "'$Item' is not a valid '$_' value. $ObjectString" }
                    }
                } elseif ($ValidValues -notcontains $Object.$_) {
                    throw "'$($Object.$_)' is not a valid '$_' value. $ObjectString"
                }
            }
        }
        @($Pattern).foreach{
            # Match property name with parameter name
            [string]$Parameter = if ($Format -and $Format.$_) { $Format.$_ } else { $_ }
            if ($Object.$_) {
                # Verify provided value matches 'ValidPattern'
                $ValidPattern = Get-ValidPattern $Command $Endpoint $Parameter
                if ($Object.$_ -notmatch $ValidPattern) {
                    throw "'$($Object.$_)' is not a valid '$_' value. $ObjectString"
                }
            }
        }
    }
}
function Convert-Rfc3339 {
    [CmdletBinding()]
    [OutputType([string])]
    param([int32]$Hours)
    process {
        # Return Rfc3339 timestamp for $Hours from Get-Date
        "$([Xml.XmlConvert]::ToString(
            (Get-Date).AddHours($Hours),[Xml.XmlDateTimeSerializationMode]::Utc) -replace '\.\d+Z$','Z')"
    }
}
function Get-ContainerUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$Registry)
    process {
        if ($Registry) {
            # Output 'registry' URL using cached 'Hostname' value
            $Script:Falcon.Hostname -replace 'api(\.us-2|\.eu-1|laggar\.gcw)?','registry'
        } else {
            # Output 'container-upload' URL using cached 'Hostname' value
            if ($Script:Falcon.Hostname -match 'api\.crowdstrike') {
                $Script:Falcon.Hostname -replace 'api','container-upload.us-1'
            } else {
                $Script:Falcon.Hostname -replace 'api','container-upload'
            }
        }
    }
}
function Get-ParamSet {
    [CmdletBinding()]
    param(
        [string]$Endpoint,
        [System.Object]$Headers,
        [System.Object]$Inputs,
        [System.Object]$Format,
        [int32]$Max,
        [string]$HostUrl
    )
    begin {
        # Get baseline switch and endpoint parameters
        $Switches = @{}
        if ($Inputs) {
            $Inputs.GetEnumerator().Where({ $_.Key -match '^(All|Detailed|Total)$' }).foreach{
                $Switches.Add($_.Key,$_.Value)
            }
        }
        $Base = @{
            Path = if ($HostUrl) {
                $HostUrl,$Endpoint.Split(':',2)[0] -join $null
            } else {
                $Script:Falcon.Hostname,$Endpoint.Split(':',2)[0] -join $null
            }
            Method = $Endpoint.Split(':')[1]
            Headers = $Headers
        }
        if (!$Max) {
            $IdCount = if ($Inputs.ids) {
                # Find maximum number of 'ids' parameter using equivalent of 500 32-character ids
                $Pmax = ($Inputs.ids | Measure-Object -Maximum -Property Length -EA 0).Maximum
                if ($Pmax) { [Math]::Floor([decimal](18500/($Pmax + 5))) }
            }
            # Output maximum, no greater than 500
            $Max = if ($IdCount -and $IdCount -lt 500) { $IdCount } else { 500 }
        }
        # Get 'Content' from user input
        $Content = Build-Content -Inputs $Inputs -Format $Format
    }
    process {
        if ($Content.Query -and ($Content.Query | Measure-Object).Count -gt $Max) {
            Write-Verbose "[Get-ParamSet] Creating groups of $Max query values"
            for ($i = 0; $i -lt ($Content.Query | Measure-Object).Count; $i += $Max) {
                # Split 'Query' values into groups
                $Split = $Switches.Clone()
                $Split.Add('Endpoint',$Base.Clone())
                $Split.Endpoint.Path += if ($Split.Endpoint.Path -match '\?') {
                    "&$($Content.Query[$i..($i + ($Max - 1))] -join '&')"
                } else {
                    "?$($Content.Query[$i..($i + ($Max - 1))] -join '&')"
                }
                $Content.GetEnumerator().Where({ $_.Key -ne 'Query' -and $_.Value }).foreach{
                    # Add values other than 'Query'
                    $Split.Endpoint.Add($_.Key,$_.Value)
                }
                ,$Split
            }
        } elseif ($Content.Body -and ($Content.Body.ids | Measure-Object).Count -gt $Max) {
            Write-Verbose "[Get-ParamSet] Creating groups of $Max 'ids'"
            for ($i = 0; $i -lt ($Content.Body.ids | Measure-Object).Count; $i += $Max) {
                # Split 'Body' content into groups using 'ids'
                $Split = $Switches.Clone()
                $Split.Add('Endpoint',$Base.Clone())
                $Split.Endpoint.Add('Body',@{ ids = $Content.Body.ids[$i..($i + ($Max - 1))] })
                $Content.GetEnumerator().Where({ $_.Value }).foreach{
                    # Add values other than 'Body.ids'
                    if ($_.Key -eq 'Query') {
                        $Split.Endpoint.Path += if ($Split.Endpoint.Path -match '\?') {
                            "&$($_.Value -join '&')"
                        } else {
                            "?$($_.Value -join '&')"
                        }
                    } elseif ($_.Key -eq 'Body') {
                        ($_.Value).GetEnumerator().Where({ $_.Key -ne 'ids' }).foreach{
                            $Split.Endpoint.Body.Add($_.Key,$_.Value)
                        }
                    } else {
                        $Split.Endpoint.Add($_.Key,$_.Value)
                    }
                }
                ,$Split
            }
        } else {
            # Use base parameters, add content and output single parameter set
            $Switches.Add('Endpoint',$Base.Clone())
            if ($Content) {
                $Content.GetEnumerator().foreach{
                    if ($_.Key -eq 'Query') {
                        $Switches.Endpoint.Path += if ($Switches.Endpoint.Path -match '\?') {
                            "&$($_.Value -join '&')"
                        } else {
                            "?$($_.Value -join '&')"
                        }
                    } else {
                        $Switches.Endpoint.Add($_.Key,$_.Value)
                    }
                }
            }
            $Switches
        }
    }
}
function Get-RtrCommand {
    [CmdletBinding()]
    param(
        [string]$Command,
        [switch]$ConfirmCommand,
        [ValidateSet('ReadOnly','Responder','Admin')]
        [string]$Permission
    )
    begin {
        # Update 'Permission' to include lower level permission(s)
        [string[]]$Permission = switch ($Permission) {
            'ReadOnly' { 'ReadOnly' }
            'Responder' { 'ReadOnly','Responder' }
            'Admin' { 'ReadOnly','Responder','Admin' }
        }
    }
    process {
        # Create table of Real-time Response commands organized by permission level
        $Index = @{}
        @($null,'Responder','Admin').foreach{
            $Key = if ($_ -eq $null) { 'ReadOnly' } else { $_ }
            $Index[$Key] = (Get-Command "Invoke-Falcon$($_)Command").Parameters.GetEnumerator().Where({
                $_.Key -eq 'Command' }).Value.Attributes.ValidValues
        }
        # Filter 'Responder' and 'Admin' to unique command(s)
        $Index.Responder = $Index.Responder | Where-Object { $Index.ReadOnly -notcontains $_ }
        $Index.Admin = $Index.Admin | Where-Object { $Index.ReadOnly -notcontains $_ -and
            $Index.Responder -notcontains $_ }
        if ($Command) {
            # Determine command to invoke using $Command and permission level
            $Result = if ($Command -eq 'runscript') {
                # Force 'Admin' for 'runscript' command
                'Invoke-FalconAdminCommand'
            } else {
                $Index.GetEnumerator().Where({ $_.Value -contains $Command }).foreach{
                    if ($_.Key -eq 'ReadOnly') { 'Invoke-FalconCommand' } else { "Invoke-Falcon$($_.Key)Command" }
                }
            }
            if ($ConfirmCommand) { $Result -replace 'Invoke','Confirm' } else { $Result }
        } elseif ($Permission) {
            # Return available Real-time Response commands by permission
            $Index.GetEnumerator().Where({ $Permission -contains $_.Key }).Value
        } else {
            # Return all available Real-time Response commands
            @($Index.Values).foreach{ $_ }
        }
    }
}
function Get-RtrResult {
    [CmdletBinding()]
    param([object[]]$Object,[object[]]$Output)
    begin {
        # Real-time Response fields to capture from results
        $RtrFields = @('aid','batch_get_cmd_req_id','batch_id','cloud_request_id','complete','errors',
            'error_message','name','offline_queued','progress','queued_command_offline','session_id','sha256',
            'size','status','stderr','stdout','task_id')
    }
    process {
        foreach ($Result in ($Object | Select-Object $RtrFields)) {
            # Update 'Output' with populated result(s) from 'Object'
            @($Result.PSObject.Properties | Where-Object { $_.Value -or $_.Value -is [boolean] }).foreach{
                $Name = if ($_.Name -eq 'task_id') {
                    # Rename 'task_id' to 'cloud_request_id'
                    'cloud_request_id'
                } elseif ($_.Name -eq 'queued_command_offline') {
                    # Rename 'queued_command_offline' to 'offline_queued'
                    'offline_queued'
                } else {
                    $_.Name
                }
                $Value = if (($_.Value -is [object[]]) -and ($_.Value[0] -is [string])) {
                    # Convert array result into string
                    $_.Value -join ', '
                } elseif ($_.Value.code -and $_.Value.message) {
                    # Convert error code and message into string
                    (($_.Value).foreach{ "$($_.code): $($_.message)" }) -join ', '
                } else {
                    $_.Value
                }
                # Update 'Output' with result using 'aid' or 'session_id'
                $Match = if ($Result.aid) { 'aid' } else { 'session_id' }
                if ($Result.$Match) {
                    @($Output | Where-Object { $Result.$Match -eq $_.$Match }).foreach{
                        Set-Property $_ $Name $Value
                    }
                }
            }
        }
    }
    end { return $Output }
}
function Invoke-Falcon {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Command,
        [string]$Endpoint,
        [System.Collections.Hashtable]$Headers,
        [System.Object]$Inputs,
        [System.Object]$Format,
        [switch]$RawOutput,
        [int32]$Max,
        [string]$HostUrl
    )
    begin {
        if (!$Script:Falcon.Api.Client.DefaultRequestHeaders.Authorization -or !$Script:Falcon.Hostname) {
            # Request initial authorization token
            Request-FalconToken
        }
        # Gather parameters for 'Get-ParamSet'
        $GetParam = @{}
        $PSBoundParameters.GetEnumerator().Where({ $_.Key -notmatch '^(Command|RawOutput)$' }).foreach{
            $GetParam.Add($_.Key,$_.Value)
        }
        # Add 'Accept: application/json' when undefined
        if (!$GetParam.Headers) { $GetParam.Add('Headers',@{}) }
        if (!$HostUrl -and !$GetParam.Headers.Accept) { $GetParam.Headers.Add('Accept','application/json') }
        if ($Format.Body -and !$GetParam.Headers.ContentType) {
            # Add 'ContentType: application/json' when undefined and 'Body' is present
            $GetParam.Headers.Add('ContentType','application/json')
        }
        if ($Format) {
            # Determine expected field values using 'Format'
            [System.Collections.Generic.List[string]]$Expected = @()
            @($Format.Values).foreach{
                if ($_ -is [array]) {
                    @($_).foreach{ $Expected.Add($_) }
                } elseif ($_.Keys) {
                    @($_.Values).foreach{ @($_).foreach{ $Expected.Add($_) }}
                }
            }
            if ($Expected) {
                @($Inputs.Keys).foreach{
                    if ($Expected -notcontains $_) {
                        # Create duplicate parameter using 'Alias' and remove original when expected
                        $Alias = ((Get-Command $Command).Parameters.$_.Aliases)[0]
                        if ($Alias -and $Expected -contains $Alias) {
                            $Inputs[$Alias] = $Inputs.$_
                            [void]$Inputs.Remove($_)
                        }
                    }
                }
            }
        }
        if ($Inputs.All -eq $true -and !$Inputs.Limit) {
            # Add maximum 'Limit' when not present and using 'All'
            $Limit = (Get-Command $Command).ParameterSets.Where({
                $_.Name -eq $Endpoint }).Parameters.Where({ $_.Name -eq 'Limit' }).Attributes.MaxRange
            if ($Limit) { $Inputs.Add('Limit',$Limit) }
        }
        # Regex for URL paths that don't need a secondary 'Detailed' request
        [regex]$NoDetail = '(/combined/|/rule-groups-full/)'
    }
    process {
        foreach ($Set in (Get-ParamSet @GetParam)) {
            [string]$Operation = $Set.Endpoint.Method.ToUpper()
            [string]$Target = New-ShouldMessage $Set.Endpoint
            try {
                # Refresh authorization token during loop
                if ($Script:Falcon.Expiration -le (Get-Date).AddSeconds(60)) { Request-FalconToken }
                if ($Set.Endpoint.Headers.ContentType -eq 'application/json' -and $Set.Endpoint.Body) {
                    # Convert body to Json
                    $Set.Endpoint.Body = ConvertTo-Json $Set.Endpoint.Body -Depth 32 -Compress
                }
                $Request = if ($PSCmdlet.ShouldProcess($Target,$Operation)) {
                    $Script:Falcon.Api.Invoke($Set.Endpoint)
                }
                if ($RawOutput) {
                    # Return result if 'RawOutput' is defined
                    $Request
                } elseif ($Set.Endpoint.Outfile -and (Test-Path $Set.Endpoint.Outfile)) {
                    # Display 'Outfile'
                    Get-ChildItem $Set.Endpoint.Outfile | Select-Object FullName,Length,LastWriteTime
                } elseif ($Request.Result.Content) {
                    # Capture pagination for 'Total' and 'All'
                    $Pagination = (ConvertFrom-Json (
                        $Request.Result.Content).ReadAsStringAsync().Result).meta.pagination
                    if ($Set.Total -eq $true -and $Pagination) {
                        # Output 'Total'
                        $Pagination.total
                    } else {
                        $Result = Write-Result $Request
                        if ($null -ne $Result) {
                            if ($Set.Detailed -eq $true -and $Set.Endpoint.Path -notmatch $NoDetail) {
                                # Output 'Detailed'
                                & $Command -Id $Result
                            } else {
                                # Output result
                                $Result
                            }
                            if ($Set.All -eq $true -and ($Result | Measure-Object).Count -lt
                            $Pagination.total) {
                                # Repeat request(s)
                                Invoke-Loop $Set $Pagination $Result
                            }
                        }
                    }
                }
            } catch {
                Write-Error $_
            }
        }
    }
}
function Invoke-Loop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Hashtable]$ParamSet,
        [Parameter(Mandatory)]
        [System.Object]$Pagination,
        [Parameter(Mandatory)]
        [System.Object]$Result
    )
    begin {
        # Regex for URL paths that don't need a secondary 'Detailed' request
        [regex]$NoDetail = '(/combined/|/rule-groups-full/)'
    }
    process {
        for ($i = ($Result | Measure-Object).Count; $Pagination.next_page -or $i -lt $Pagination.total;
        $i += ($Result | Measure-Object).Count) {
            Write-Verbose "[Invoke-Loop] $i of $($Pagination.total)"
            # Clone endpoint parameters and update pagination
            $Clone = $ParamSet.Clone()
            $Clone.Endpoint = $ParamSet.Endpoint.Clone()
            $Page = if ($Pagination.after) {
                @('after',$Pagination.after)
            } elseif ($Pagination.next_token) {
                @('next_token',$Pagination.next_token)
            } elseif ($Pagination.next_page) {
                @('offset',$Pagination.offset)
            } elseif ($Pagination.offset -match '^\d{1,}$') {
                @('offset',$i)
            } else {
                @('offset',$Pagination.offset)
            }
            $Clone.Endpoint.Path = if ($Clone.Endpoint.Path -match "$($Page[0])=\d{1,}") {
                # If offset was input, continue from that value
                $Current = [regex]::Match($Clone.Endpoint.Path,'offset=(\d+)(^&)?').Captures.Value
                $Page[1] += [int]$Current.Split('=')[-1]
                $Clone.Endpoint.Path -replace $Current,($Page -join '=')
            } elseif ($Clone.Endpoint.Path -match "$Endpoint^" -and $Clone.Endpoint.Path -notmatch '\?') {
                # Add pagination
                $Clone.Endpoint.Path,($Page -join '=') -join '?'
            } else {
                # Update pagination
                $Clone.Endpoint.Path,($Page -join '=') -join '&'
            }
            $Request = $Script:Falcon.Api.Invoke($Clone.Endpoint)
            if ($Request.Result.Content) {
                $Result = Write-Result $Request
                if ($null -ne $Result) {
                    if ($Clone.Detailed -eq $true -and $Clone.Endpoint.Path -notmatch $NoDetail) {
                        & $Command -Id $Result
                    } else {
                        $Result
                    }
                } else {
                    [string]$Message = "[Invoke-Loop] Results limited by API '$(($Clone.Endpoint.Path).Split(
                        '?')[0] -replace $Script:Falcon.Hostname,$null)' ($i of $($Pagination.total))."
                    Write-Error $Message
                }
                $Pagination = (ConvertFrom-Json (
                    $Request.Result.Content).ReadAsStringAsync().Result).meta.pagination
            }
        }
    }
}
function New-ShouldMessage {
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([System.Collections.Hashtable]$Object)
    process {
        try {
            $Output = [PSCustomObject]@{}
            if ($Object.Path) {
                [string]$Path = $Object.Path
                if ($Path -match $Script:Falcon.Hostname) {
                    # Add 'Hostname' when using cached hostname value
                    Set-Property $Output Hostname $Script:Falcon.Hostname
                    $Path = $Path -replace $Script:Falcon.Hostname,$null
                }
                if ($Path -match '\?') {
                    # Add 'Path' without query values
                    [string[]]$Array = $Path -split '\?'
                    [string[]]$Query = $Array[-1] -split '&'
                    Set-Property $Output Path $Array[0]
                } else {
                    Set-Property $Output Path $Path
                }
            }
            if ($Object.Headers) {
                # Add 'Headers' value
                Set-Property $Output Headers ($Object.Headers.GetEnumerator().foreach{
                    $_.Key,$_.Value -join '=' } -join ', ')
            }
            if ($Query) {
                # Add 'Query' value as an array
                Set-Property $Output Query $Query
            }
            foreach ($Pair in $Object.GetEnumerator().Where({ $_.Key -ne '^(Headers|Method|Path)$' })) {
                [string]$Value = switch ($Pair.Key) {
                    'Body' {
                        # Convert 'Body' to Json
                        $Pair.Value | ConvertTo-Json -Depth 8
                    }
                }
                if ($Value) { Set-Property $Output $Pair.Key $Value }
            }
            "`r`n",($Output | Format-List | Out-String).Trim(),"`r`n" -join "`r`n"
        } catch {}
    }
}
function Set-Property {
    [CmdletBinding()]
    [OutputType([void])]
    param([System.Object]$Object,[string]$Name,[System.Object]$Value)
    process {
        if ($Object.$Name) {
            # Update existing property
            $Object.$Name = $Value
        } else {
            # Add property to [PSCustomObject]
            $Object.PSObject.Properties.Add((New-Object PSNoteProperty($Name,$Value)))
        }
    }
}
function Test-FqlStatement {
    [CmdletBinding()]
    [OutputType([boolean])]
    param(
        [Parameter(Mandatory)]
        [string]$String
    )
    begin {
        $Pattern = [regex]("(?<FqlProperty>[\w\.]+):(?<FqlOperator>(!~?|~|(>|<)=?|\*)?)" +
            "(?<FqlValue>[\w\d\s\.\-\*\[\]\\,'`":]+)")
    }
    process {
        if ($String -notmatch $Pattern) {
            # Error when 'filter' does not match $Pattern
            throw "'$String' is not a valid Falcon Query Language statement."
        } else {
            $true
        }
    }
}
function Test-OutFile {
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param([string]$Path)
    process {
        if (!$Path) {
            @{
                # Generate parameters for 'Write-Error' if 'Path' is not present
                Message = "Missing required parameter 'Path'."
                Category = [System.Management.Automation.ErrorCategory]::ObjectNotFound
            }
        } elseif ($Path -is [string] -and ![string]::IsNullOrEmpty($Path) -and (Test-Path $Path) -eq $true) {
            @{
                # Generate parameters for 'Write-Error' if 'Path' already exists
                Message = "An item with the specified name $Path already exists."
                Category = [System.Management.Automation.ErrorCategory]::WriteError
                TargetName = $Path
            }
        }
    }
}
function Test-RegexValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$String
    )
    begin {
        $RegEx = @{
            md5    = [regex]'^[A-Fa-f0-9]{32}$'
            sha256 = [regex]'^[A-Fa-f0-9]{64}$'
            ipv4   = [regex]'^([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.'
            ipv6   = [regex]'^[0-9a-fA-F]{1,4}:'
            domain = [regex]'^(https?://)?((?=[a-z0-9-]{1,63}\.)(xn--)?[a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,63}$'
            email  = [regex]"^\w+([-+.']\w+)*@\w+([-.]\w+)*\.\w+([-.]\w+)*$"
            tag    = [regex]'^[-\w\d_/]+$'
        }
    }
    process {
        $Output = ($RegEx.GetEnumerator()).foreach{
            if ($String -match $_.Value) {
                if ($_.Key -match '^(ipv4|ipv6)$') {
                    # Use initial RegEx match, then validate IP and return type
                    if (($String -as [System.Net.IPAddress] -as [bool]) -eq $true) { $_.Key }
                } else {
                    # Return type
                    $_.Key
                }
            }
        }
    }
    end {
        if ($Output) {
            Write-Verbose "[Test-RegexValue] $(@($Output,$String) -join ': ')"
            $Output
        }
    }
}
function Write-Result {
    [CmdletBinding()]
    param([System.Object]$Request)
    begin {
        function Write-Meta ($Object) {
            # Convert [array] and [PSCustomObject] into a flat Verbose output message
            function arr ($Array,$Output,$String) {
                @($Array).foreach{
                    if ($_.GetType().Name -eq 'PSCustomObject') {
                        obj $_ $Output $String
                    } else {
                        $Output[$String] = $_ -join ','
                    }
                }
            }
            function obj ($Object,$Output,$String) {
                $Object.PSObject.Members.Where({ $_.MemberType -eq 'NoteProperty' }).foreach{
                    $Name = if ($String) { @($String,$_.Name) -join '.' } else { $_.Name }
                    if ($_.Value.GetType().Name -eq 'PSCustomObject') {
                        obj $_.Value $Output $Name
                    } elseif ($_.Value.GetType().Name -eq 'Object[]') {
                        arr $_.Value $Output $Name
                    } else {
                        $Output[$Name] = $_.Value -join ','
                    }
                }
            }
            $Output = @{}
            @($Object).Where({ $_.GetType().Name -eq 'PSCustomObject' }).foreach{ obj $_ $Output }
            if ($Output) {
                Write-Verbose "[Write-Result] $($Output.GetEnumerator().foreach{ @((@('meta',$_.Key) -join '.'),
                    $_.Value) -join '=' } -join ', ')"
            }
        }
    }
    process {
        # Capture result content
        $Result = if ($Request.Result.Content) { ($Request.Result.Content).ReadAsStringAsync().Result }
        [string]$TraceId = if ($Request.Result.Headers) {
            # Capture trace_id for error messages
            $Request.Result.Headers.GetEnumerator().Where({ $_.Key -eq 'X-Cs-Traceid' }).Value
        }
        # Convert content to Json
        $Json = if ($Result -and $Request.Result.Content.Headers.ContentType -eq 'application/json' -or
        $Request.Result.Content.Headers.ContentType.MediaType -eq 'application/json') {
            ConvertFrom-Json $Result
        }
        if ($Json) {
            # Gather field names from result, excluding 'errors', 'extensions', and 'meta'
            [string[]]$ResponseFields = @($Json.PSObject.Properties).Where({ $_.Name -notmatch
                '^(errors|extensions|meta)$' -and $_.Value }).foreach{ $_.Name }
            # Write verbose 'meta' output
            if ($Json.meta) { Write-Meta $Json.meta }
            if ($ResponseFields) {
                if (($ResponseFields | Measure-Object).Count -gt 1) {
                    # Output all fields by name
                    $Json | Select-Object $ResponseFields
                } elseif ($ResponseFields -eq 'combined' -and $Json.$ResponseFields.PSObject.Properties.Name -eq
                'resources' -and ($Json.$ResponseFields.PSObject.Properties.Name | Measure-Object).Count -eq 1) {
                    # Output values under 'combined.resources'
                    $Json.$ResponseFields.resources.PSObject.Properties.Value
                } elseif ($ResponseFields -eq 'resources' -and $Json.$ResponseFields.PSObject.Properties.Name -eq
                'events' -and ($Json.$ResponseFields.PSObject.Properties.Name | Measure-Object).Count -eq 1) {
                    # Output 'resources.events'
                    $Json.$ResponseFields.events
                } else {
                    # Output single field
                    $Json.$ResponseFields
                }
            } elseif ($Json.meta) {
                # Output 'meta' fields when nothing else is available
                [string[]]$MetaFields = @($Json.meta.PSObject.Properties).Where({ $_.Name -notmatch
                    '^(entity|pagination|powered_by|query_time|trace_id)$' }).foreach{ $_.Name }
                if ($MetaFields) { $Json.meta | Select-Object $MetaFields }
            }
            @($Json.PSObject.Properties).Where({ $_.Name -eq 'errors' -and $_.Value }).foreach{
                # Output error
                $Message = ConvertTo-Json $_.Value -Compress
                $PSCmdlet.WriteError(
                    [System.Management.Automation.ErrorRecord]::New(
                        [Exception]::New($Message),
                        $TraceId,
                        [System.Management.Automation.ErrorCategory]::InvalidResult,
                        $Request
                    )
                )
            }
        } else {
            # Output non-Json content
            $Result
        }
        # Check for rate limiting
        Wait-RetryAfter $Request
    }
}
function Wait-RetryAfter {
    [CmdletBinding()]
    param([System.Object]$Request)
    process {
        if ($Request.Result.StatusCode -and $Request.Result.StatusCode.GetHashCode() -eq 429 -and
        $Request.Result.RequestMessage.RequestUri.AbsolutePath -ne '/oauth2/token') {
            # Convert 'X-Ratelimit-Retryafter' value to seconds and wait
            $Wait = [System.DateTimeOffset]::FromUnixTimeSeconds(($Request.Result.Headers.GetEnumerator().Where({
                $_.Key -eq 'X-Ratelimit-Retryafter' }).Value)).Second
            Write-Verbose "[Wait-RetryAfter] Rate limited for $Wait seconds..."
            Start-Sleep -Seconds $Wait
        }
    }
    end { if ($Request) { $Request.Dispose() }}
}