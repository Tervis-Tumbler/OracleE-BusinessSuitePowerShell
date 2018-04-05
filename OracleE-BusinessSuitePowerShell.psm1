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

function Get-EBSPerson {
    param (
        [String]$FIRST_NAME,
        [String]$LAST_NAME,
        [String]$EMPLOYEE_NUMBER,
        [ValidateSet("Y","N")]$CURRENT_EMPLOYEE_FLAG
    )
     Invoke-EBSSQL -SQLCommand @"
select * 
from apps.per_all_people_f
where 1 = 1
$(if ($FIRST_NAME) {"AND apps.per_all_people_f.FIRST_NAME = '$($FIRST_NAME.ToUpper())'"})
$(if ($LAST_NAME) {"AND apps.per_all_people_f.LAST_NAME = '$($LAST_NAME.ToUpper())'"})
$(if ($EMPLOYEE_NUMBER) {"AND apps.per_all_people_f.EMPLOYEE_NUMBER = '$($EMPLOYEE_NUMBER.ToUpper())'"})
$(if ($CURRENT_EMPLOYEE_FLAG) {"AND apps.per_all_people_f.CURRENT_EMPLOYEE_FLAG = '$CURRENT_EMPLOYEE_FLAG'"})
"@
}

function Get-EBSUser {
    param (
        $USER_NAME
    )
    $TableName = "APPS.FND_USER"
    Invoke-EBSSQL -SQLCommand @"
select * 
from $TableName
where 1 = 1
$(if ($USER_NAME) {"AND $TableName.USER_NAME = '$($USER_NAME.ToUpper())'"})
"@
}

function Get-EBSResponsibility {
    param (
        [String]$RESPONSIBILITY_NAME
    )
    $TableName = "APPS.FND_USER"
    Invoke-EBSSQL -SQLCommand @"
select *
from 
APPS.FND_RESPONSIBILITY_TL FRT, 
APPS.FND_RESPONSIBILITY FR
where 1 = 1
AND FRT.RESPONSIBILITY_ID = FR.RESPONSIBILITY_ID
$(if ($RESPONSIBILITY_NAME) {"AND FRT.RESPONSIBILITY_NAME = '$($RESPONSIBILITY_NAME)'"})
"@
}

function New-EBSSQLWhere {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$Parameters,
        [Parameter(Mandatory)]$TableName
    )

    "where 1 = 1"
    foreach ($Parameter in $Parameters) {
        "AND $TableName.$($Parameter.Name) = '$($Parameter.Value.ToUpper())'"
    }

}