function New-EBSPowershellConfiguration {
    param (
        [Parameter(Mandatory,ParameterSetName="DatabaseConnectionString")][String]$DatabaseConnectionString,
        [Parameter(Mandatory,ParameterSetName="NoDatabaseConnectionString")][string]$Host,
        [Parameter(Mandatory,ParameterSetName="NoDatabaseConnectionString")][string]$Port,
        [Parameter(Mandatory,ParameterSetName="NoDatabaseConnectionString")][string]$Service_Name,
        [Parameter(Mandatory,ParameterSetName="NoDatabaseConnectionString")][string]$UserName,
        [Parameter(Mandatory,ParameterSetName="NoDatabaseConnectionString")][string]$Password,
        [Parameter(ParameterSetName="NoDatabaseConnectionString")][string]$Protocol = "TCP",

        $RootCredential,
        $ApplmgrCredential,
        $AppsCredential,
        $InternetApplicationServerComputerName
    )
    $Parameters = $PSBoundParameters

    if (-not $DatabaseConnectionString) {
        $DatabaseConnectionString = $Parameters |
        ConvertFrom-PSBoundParameters -Property Host,Port,Service_Name,UserName,Password,Protocol |
        ConvertTo-OracleConnectionString
    }

    $Parameters | 
    ConvertFrom-PSBoundParameters -ExcludeProperty Host,Port,Service_Name,UserName,Password,Protocol,DatabaseConnectionString -Property *,@{
        Name = "DatabaseConnectionString"
        Expression = {$DatabaseConnectionString}
    }
}

function Get-EBSIASNode {
    [PSCustomObject]@{
        ComputerName = $Script:Configuration.InternetApplicationServerComputerName
        Credential = $Script:Configuration.ApplmgrCredential
    } | 
    Add-SSHSessionCustomProperty -PassThru -UseIPAddress:$false | 
    Add-SFTPSessionCustomProperty -PassThru -UseIPAddress:$false
}

function Get-EBSPowershellConfiguration {
    $Script:Configuration
}

function Set-EBSPowershellConfiguration {
    param (
        [PSObject]$Configuration
    )
    $Script:Configuration = $Configuration
}

function Invoke-EBSIASSSHCommand {
    param (
        $Command
    )
    $EBSIASNode = Get-EBSIASNode
    Invoke-SSHCommand -SSHSession $EBSIASNode.SSHSession -Command $Command |
    Select-Object -ExpandProperty Output
}

function Get-EBSFNDLoad {
    param (
        [Parameter(Mandatory)]$ResponsibilityName
    )
    $Responsibility = Get-EBSResponsibility -RESPONSIBILITY_NAME $ResponsibilityName
    
    if (-not $Responsibility) { Throw "No responsiblity found with the name $ResponsibilityName" }
@"
. /u01/app/applmgr/DEV/apps_st/appl/APPSDEV_dlt-ias01.env
cd /tmp
FNDLOAD $($Script:Configuration.AppsCredential.username)/$($Script:Configuration.AppsCredential.getNetworkCredential().password) 0 Y DOWNLOAD `$FND_TOP/patch/115/import/afscursp.lct TempExport.ldt FND_RESPONSIBILITY RESP_KEY=”$($Responsibility.RESPONSIBILITY_KEY)”
"@
#    Invoke-EBSIASSSHCommand -command @"
#
#"@
Get-SFTPSession
}

function Invoke-EBSSQL {
    param (
        [Parameter(Mandatory)][String]$SQLCommand
    )
    Invoke-SQLGeneric -DatabaseEngineClassMapName Oracle -ConnectionString $Script:Configuration.DatabaseConnectionString -SQLCommand $SQLCommand -ConvertFromDataRow
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