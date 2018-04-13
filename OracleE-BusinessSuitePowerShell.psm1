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

function Get-EBSPowershellConfiguration {
    $Script:Configuration
}

function Set-EBSPowershellConfiguration {
    param (
        [PSObject]$Configuration
    )
    $Script:Configuration = $Configuration
}

function Get-EBSIASNode {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    [PSCustomObject]@{
        ComputerName = $EBSEnvironmentConfiguration.InternetApplicationServerComputerName
        Credential = $EBSEnvironmentConfiguration.ApplmgrCredential
    } | 
    Add-SSHSessionCustomProperty -PassThru -UseIPAddress:$false | 
    Add-SFTPSessionCustomProperty -PassThru -UseIPAddress:$false
}

function Invoke-EBSIASSSHCommand {
    param (
        [Parameter(Mandatory)]$Command,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    $EBSIASNode = Get-EBSIASNode
    Invoke-SSHCommand -SSHSession $EBSIASNode.SSHSession -Command $Command |
    Select-Object -ExpandProperty Output
}

function Get-EBSFNDLoad {
    param (
        [Parameter(Mandatory)]$ResponsibilityName,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    $Responsibility = Get-EBSResponsibility -RESPONSIBILITY_NAME $ResponsibilityName -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration
    
    if (-not $Responsibility) { Throw "No responsiblity found with the name $ResponsibilityName" }
    
    $FNDLoadCredentialParameter = $($EBSEnvironmentConfiguration.AppsCredential.username)/$($EBSEnvironmentConfiguration.AppsCredential.getNetworkCredential().password)

    $Command = @"
. /u01/app/applmgr/DEV/apps_st/appl/APPSDEV_dlt-ias01.env
cd /tmp
FNDLOAD $FNDLoadCredentialParameter 0 Y DOWNLOAD `$FND_TOP/patch/115/import/afscursp.lct TempExport.ldt FND_RESPONSIBILITY RESP_KEY="$($Responsibility.RESPONSIBILITY_KEY)"
"@
    $EBSIASNode = Get-EBSIASNode -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration
    Invoke-SSHCommand -SSHSession $EBSIASNode.SSHSession -Command $Command |
    Select-Object -ExpandProperty Output

    $ResponsibilityDefinition = Get-SFTPContent -SFTPSession $EBSIASNode.SFTPSession -Path "/tmp/TempExport.ldt"
    Get-SFTPFile -SFTPSession $EBSIASNode.SFTPSession -RemoteFile "/tmp/TempExport.ldt" -LocalPath "$env:TEMP"

    Set-SFTPFile -SFTPSession $EBSIASNode.SFTPSession -LocalFile "$env:TEMP\TempExport.ldt" -RemotePath "/tmp"

    $Command = @"
. /u01/app/applmgr/DEV/apps_st/appl/APPSDEV_dlt-ias01.env
cd /tmp
FNDLOAD $FNDLoadCredentialParameter 0 Y UPLOAD `$FND_TOP/patch/115/import/afscursp.lct TempExport.ldt"
"@
}

function Invoke-EBSSQL {
    param (
        [Parameter(Mandatory)][String]$SQLCommand,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    Invoke-SQLGeneric -DatabaseEngineClassMapName Oracle -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -ConvertFromDataRow |
    Remove-PSObjectEmptyOrNullProperty
}

function Get-EBSUserNameAndResponsibility {
    param (
        [Parameter(Mandatory)]$EBSEnvironmentConfiguration
    )
    Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand @"
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
        [ValidateSet("Y","N")]$CURRENT_EMPLOYEE_FLAG,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
     Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand @"
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
        $USER_NAME,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    $TableName = "APPS.FND_USER"
    Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand @"
select * 
from $TableName
where 1 = 1
$(if ($USER_NAME) {"AND $TableName.USER_NAME = '$($USER_NAME.ToUpper())'"})
"@
}

function Get-EBSResponsibility {
    param (
        [String]$RESPONSIBILITY_NAME,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    $TableName = "APPS.FND_USER"
    Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand @"
select *
from 
APPS.FND_RESPONSIBILITY_TL FRT, 
APPS.FND_RESPONSIBILITY FR
where 1 = 1
AND FRT.RESPONSIBILITY_ID = FR.RESPONSIBILITY_ID
$(if ($RESPONSIBILITY_NAME) {"AND FRT.RESPONSIBILITY_NAME = '$($RESPONSIBILITY_NAME)'"})
"@
}

function Get-EBSProfileOptionWithValuesCount {
    param (
        [String]$RESPONSIBILITY_NAME,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    $TableName = "APPS.FND_USER"
    Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand @"
select count (*) from (
  select count(*)
  from  apps.FND_PROFILE_OPTION_VALUES
  group by Application_ID, Profile_Option_ID
);
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

function Get-EBSTradingCommunityArchitectureParty {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Parameter(Mandatory,ValueFromPipelineByPropertyName,ParameterSetName="Party_ID")]$Party_ID
    )
    process {
        $SQLCommand = New-EBSSQLSelect -Parameters $PSBoundParameters -TableName hz_parties
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function Get-EBSTradingCommunityArchitectureOrganiztaionContact {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Parameter(ValueFromPipelineByPropertyName)]$org_contact_id,
        [Parameter(ValueFromPipelineByPropertyName)]$party_relationship_id,
        [Parameter(ValueFromPipelineByPropertyName)]$PARTY_SITE_ID
    )
    process {
        $SQLCommand = New-EBSSQLSelect -TableName hz_org_contacts -Parameters $PSBoundParameters
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function New-EBSSQLSelect {
    param (
        [Parameter(Mandatory)]$TableName,
        [Parameter(Mandatory)]$Parameters
    )
    $ParametersToInclude = $Parameters.GetEnumerator() | 
    where key -ne "EBSEnvironmentConfiguration"

    $OFSBeforeChange = $OFS
    $OFS = ""
@"
select *
from 
$TableName
where 1 = 1
$($ParametersToInclude | New-EBSSQLWhereCondition -TableName $TableName)
"@
    $OFS = $OFSBeforeChange
}

function New-EBSSQLWhereCondition {
    param (
        [Parameter(Mandatory)]$TableName,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$Key,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$Value
    )
    process {
        "AND $TableName.$Key = '$Value'"
    }
}

function Get-EBSTradingCommunityArchitecturePartySite {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Parameter(Mandatory,ValueFromPipelineByPropertyName,ParameterSetName="Party_ID")]$Party_ID
    )
    process {
        $SQLCommand = New-EBSSQLSelect -Parameters $PSBoundParameters -TableName HZ_PARTY_SITES 
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function Get-EBSTradingCommunityArchitectureLocation {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Parameter(Mandatory,ValueFromPipelineByPropertyName,ParameterSetName="Party_ID")]$Location_ID
    )
    process {
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand @"
select 
LOCATION_ID ,
LAST_UPDATE_DATE ,
LAST_UPDATED_BY ,
CREATION_DATE ,
CREATED_BY ,
LAST_UPDATE_LOGIN ,
REQUEST_ID ,
PROGRAM_APPLICATION_ID ,
PROGRAM_ID ,
PROGRAM_UPDATE_DATE ,
WH_UPDATE_DATE ,
ATTRIBUTE_CATEGORY ,
ATTRIBUTE1 ,
ATTRIBUTE2 ,
ATTRIBUTE3 ,
ATTRIBUTE4 ,
ATTRIBUTE5 ,
ATTRIBUTE6 ,
ATTRIBUTE7 ,
ATTRIBUTE8 ,
ATTRIBUTE9 ,
ATTRIBUTE10 ,
ATTRIBUTE11 ,
ATTRIBUTE12 ,
ATTRIBUTE13 ,
ATTRIBUTE14 ,
ATTRIBUTE15 ,
ATTRIBUTE16 ,
ATTRIBUTE17 ,
ATTRIBUTE18 ,
ATTRIBUTE19 ,
ATTRIBUTE20 ,
GLOBAL_ATTRIBUTE_CATEGORY ,
GLOBAL_ATTRIBUTE1 ,
GLOBAL_ATTRIBUTE2 ,
GLOBAL_ATTRIBUTE3 ,
GLOBAL_ATTRIBUTE4 ,
GLOBAL_ATTRIBUTE5 ,
GLOBAL_ATTRIBUTE6 ,
GLOBAL_ATTRIBUTE7 ,
GLOBAL_ATTRIBUTE8 ,
GLOBAL_ATTRIBUTE9 ,
GLOBAL_ATTRIBUTE10 ,
GLOBAL_ATTRIBUTE11 ,
GLOBAL_ATTRIBUTE12 ,
GLOBAL_ATTRIBUTE13 ,
GLOBAL_ATTRIBUTE14 ,
GLOBAL_ATTRIBUTE15 ,
GLOBAL_ATTRIBUTE16 ,
GLOBAL_ATTRIBUTE17 ,
GLOBAL_ATTRIBUTE18 ,
GLOBAL_ATTRIBUTE19 ,
GLOBAL_ATTRIBUTE20 ,
ORIG_SYSTEM_REFERENCE ,
COUNTRY ,
ADDRESS1 ,
ADDRESS2 ,
ADDRESS3 ,
ADDRESS4 ,
CITY ,
POSTAL_CODE ,
STATE ,
PROVINCE ,
COUNTY ,
ADDRESS_KEY ,
ADDRESS_STYLE ,
VALIDATED_FLAG ,
ADDRESS_LINES_PHONETIC ,
APARTMENT_FLAG ,
PO_BOX_NUMBER ,
HOUSE_NUMBER ,
STREET_SUFFIX ,
APARTMENT_NUMBER ,
SECONDARY_SUFFIX_ELEMENT ,
STREET ,
RURAL_ROUTE_TYPE ,
RURAL_ROUTE_NUMBER ,
STREET_NUMBER ,
BUILDING ,
FLOOR ,
SUITE ,
ROOM ,
POSTAL_PLUS4_CODE ,
TIME_ZONE ,
OVERSEAS_ADDRESS_FLAG ,
POST_OFFICE ,
POSITION ,
DELIVERY_POINT_CODE ,
LOCATION_DIRECTIONS ,
ADDRESS_EFFECTIVE_DATE ,
ADDRESS_EXPIRATION_DATE ,
ADDRESS_ERROR_CODE ,
CLLI_CODE ,
DODAAC ,
TRAILING_DIRECTORY_CODE ,
LANGUAGE ,
LIFE_CYCLE_STATUS ,
SHORT_DESCRIPTION ,
DESCRIPTION ,
CONTENT_SOURCE_TYPE ,
LOC_HIERARCHY_ID ,
SALES_TAX_GEOCODE ,
SALES_TAX_INSIDE_CITY_LIMITS ,
FA_LOCATION_ID ,
OBJECT_VERSION_NUMBER ,
CREATED_BY_MODULE ,
APPLICATION_ID ,
TIMEZONE_ID ,
GEOMETRY_STATUS_CODE ,
ACTUAL_CONTENT_SOURCE ,
VALIDATION_STATUS_CODE ,
DATE_VALIDATED ,
DO_NOT_VALIDATE_FLAG ,
GEOMETRY_SOURCE 
from 
hz_locations
where 1 = 1
$(if ($Location_ID) {"AND hz_locations.Location_ID = '$($Location_ID)'"})
"@
    }
}

function Get-EBSTradingCommunityArchitectureCustomerAccount {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Parameter(Mandatory,ParameterSetName="Cust_Account_ID")]$Cust_Account_ID,
        [Parameter(Mandatory,ParameterSetName="Account_Number")]$Account_Number,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName,ParameterSetName="Party_ID")]$Party_ID
    )
    process {
        $SQLCommand = New-EBSSQLSelect -TableName hz_cust_accounts -Parameters $PSBoundParameters
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function Get-EBSTradingCommunityArchitectureRelationship {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Parameter(ValueFromPipelineByPropertyName)]$Party_ID,
        [Parameter(ValueFromPipelineByPropertyName)]$object_id
    )
    process {
        $SQLCommand = New-EBSSQLSelect -TableName hz_relationships -Parameters $PSBoundParameters
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function Get-EBSTradingCommunityArchitectureContactPoint {
    [Cmdletbinding(DefaultParameterSetName="EmailAddress")]
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Parameter(Mandatory,ParameterSetName="EmailAddress")]$EmailAddress,
        
        [ValidatePattern("\d{3}")][
        Parameter(Mandatory,ParameterSetName="PhoneNumber")]
        $PhoneNumberAreaCode,
        
        [ValidatePattern("\d{3}-\d{4}")]
        [Parameter(Mandatory,ParameterSetName="PhoneNumber")]
        $PhoneNumberWithoutAreaCodeWithDash
    )
    Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand @"
select *
from 
hz_contact_points
where 1 = 1
$(if ($EmailAddress) {"AND UPPER(hz_contact_points.email_address) = UPPER('$($EmailAddress)')"})
$(if ($PhoneNumberAreaCode) {"AND hz_contact_points.phone_area_code = '$($PhoneNumberAreaCode)'"})
$(if ($PhoneNumberWithoutAreaCodeWithDash) {"AND hz_contact_points.phone_number = '$($PhoneNumberWithoutAreaCodeWithDash)'"})
"@
}

function Get-EBSTradingCommunityArchitectureCustomerAccountSite {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$cust_account_id
    )
    process {
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand @"
select *
from 
hz_cust_acct_sites_all
where 1 = 1
$(if ($cust_account_id) {"AND hz_cust_acct_sites_all.cust_account_id = $($cust_account_id)"})
"@
    }
}

function Get-EBSTradingCommunityArchitectureCustomerSiteUse {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand @"
select *
from 
hz_cust_site_uses_all
where rownum <= 10
"@
}

function Get-EBSRelationshipFromEmail {
    param (
        [Parameter(Mandatory)]$EmailAddress
    )

    Get-EBSTradingCommunityArchitectureContactPoint -EmailAddress $EmailAddress |
    ForEach-Object -Process {
        [PSCustomObject]@{
            Party_ID = $_.OWNER_TABLE_ID
        }
    } |
    Get-EBSTradingCommunityArchitectureRelationship
}

function Get-EBSContactFromEmail {
    param (
        [Parameter(Mandatory)]$EmailAddress
    )
    Get-EBSRelationshipFromEmail -EmailAddress $EmailAddress | 
    where RELATIONSHIP_TYPE -EQ "Contact" |
    ForEach-Object -Process {
        [PSCustomObject]@{
            Party_ID = $_.subject_id
        }
    } |
    Get-EBSTradingCommunityArchitectureParty
}

function Get-EBSCustomerAccountFromEmail {
    param (
        [Parameter(Mandatory)]$EmailAddress
    )

    Get-EBSRelationshipFromEmail -EmailAddress $EmailAddress | 
    where RELATIONSHIP_TYPE -EQ "Contact" |
    ForEach-Object -Process {
        [PSCustomObject]@{
            Party_ID = $_.object_id
        }
    } |
    Get-EBSTradingCommunityArchitectureCustomerAccount
}

function Get-EBSOrganiztaionFromEmail {
    param (
        [Parameter(Mandatory)]$EmailAddress
    )
    Get-EBSCustomerAccountFromEmail -EmailAddress $EmailAddress |
    Get-EBSTradingCommunityArchitectureParty
}

function Get-EBSTradingCommunityArchitectureOrganizationObject {
    param (
        [Parameter(Mandatory)]$Party_ID
    )
    Get-EBSTradingCommunityArchitectureParty -Party_ID $Party_ID |
    Add-Member -MemberType ScriptProperty -Name Account -PassThru -Value {
        Get-EBSTradingCommunityArchitectureCustomerAccountObject -Party_ID $This.PARTY_ID
    } |
    Add-Member -MemberType ScriptProperty -Name Contacts -PassThru -Value {
        Get-EBSTradingCommunityArchitectureRelationship -object_id $This.Party_ID |
        foreach {
            Get-EBSTradingCommunityArchitectureOrganiztaionContact -party_relationship_id $_.RELATIONSHIP_ID |
            where {-not $_.Party_Site_ID }
        }        
    }
}

function Get-EBSTradingCommunityArchitectureCustomerAccountObject {
    param (
        [Parameter(Mandatory)]$Party_ID
    )
    Get-EBSTradingCommunityArchitectureCustomerAccount -Party_ID $PARTY_ID |
    Add-Member -MemberType ScriptProperty -Name Sites -PassThru -Value {
        Get-EBSTradingCommunityArchitectureSiteObject -Party_ID $This.PARTY_ID
    }
}

function Get-EBSTradingCommunityArchitectureSiteObject {
    param (
        [Parameter(Mandatory)]$Party_ID
    )
    Get-EBSTradingCommunityArchitecturePartySite -Party_ID $PARTY_ID |
    Add-Member -MemberType ScriptProperty -PassThru -Name Contacts -Value {        
        Get-EBSTradingCommunityArchitectureOrganiztaionContact -PARTY_SITE_ID $This.PARTY_SITE_ID
    }
}

function Get-EBSTradingCommunityArchitectureContactObject {
    Get-EBSTradingCommunityArchitectureRelationship -object_id
}