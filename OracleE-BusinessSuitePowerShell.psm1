function Get-EBSConnectionString {
    if ($Script:EBSConnectionString) {
        $Script:EBSConnectionString
    } else {
        throw "Set-EBSConnectionString must be called at least once before running Get-EBSConnectionString. Use ConvertTo-OracleConnectionString to generate a valid connection string."
    }
}

function Set-EBSConnectionString {
    param (
        [Parameter(Mandatory)][String]$ConnectionString
    )
    $Script:EBSConnectionString = $ConnectionString
}


function Invoke-EBSSQL {
    param (
        [Parameter(Mandatory)][String]$SQLCommand
    )
    $EBSConnectionString = Get-EBSConnectionString

    Invoke-SQLGeneric -DatabaseEngineClassMapName Oracle -ConnectionString $EBSConnectionString -SQLCommand $SQLCommand -ConvertFromDataRow
}

function Get-EBSUserNameAndResponsibility {
    Invoke-EBSSQL -SQLCommand @"
select distinct usr.user_name
  ,usr.description
  ,resp.responsibility_name
from FND_USER_RESP_GROUPS urep
  ,FND_RESPONSIBILITY_TL resp
  ,FND_USER usr
where urep.end_date      is null
and usr.end_date         is null
and urep.user_id          =usr.user_id
and urep.responsibility_id=resp.responsibility_id
order by 1
"@
}