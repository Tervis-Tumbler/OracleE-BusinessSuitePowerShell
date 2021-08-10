$ModulePath = if ($PSScriptRoot) {
	$PSScriptRoot
} else {
	(Get-Module -ListAvailable OracleE-BusinessSuitePowerShell).ModuleBase
}

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
        $SysCredential,
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
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        $Parameters
    )
    if ($EBSEnvironmentConfiguration) {
        Invoke-OracleSQL -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -ConvertFromDataRow -Parameters $Parameters |
        Remove-PSObjectEmptyOrNullProperty |
        Remove-EBSSQLPropertiesWeDontCareAbout
    } else {
        Throw "Invoke-EBSSQL EBSEnvironmentConfiguration not set"
    }

}

$Script:ColumnNameCache = @{}

function Get-EBSSQLTableColumnName {
    param (
        [Parameter(Mandatory)]$TableName,
        $OwnerSchemaUser
    )
    $ColumnNames = $Script:ColumnNameCache[$TableName]
    if ( -not $ColumnNames) {
        $ColumnNames = Invoke-EBSSQL -SQLCommand @"
select COLUMN_NAME 
from ALL_TAB_COLUMNS
where 1 = 1
$(if($OwnerSchemaUser) {"AND OWNER = '$($OwnerSchemaUser.ToUpper())'"})
AND TABLE_NAME = '$($TableName.ToUpper())'
order by COLUMN_NAME
"@ | 
        Select-Object -ExpandProperty COLUMN_NAME
        
        if ($ColumnNames) {
            $Script:ColumnNameCache.Add($TableName, $ColumnNames)
        }
    }
    $ColumnNames
}

$Script:PropertiesWeDontCareAbout = @"
ACTUAL_CONTENT_SOURCE
CREATED_BY
CREATED_BY_MODULE
CREATION_DATE
LAST_UPDATED_BY
LAST_UPDATE_DATE
LAST_UPDATE_LOGIN
OBJECT_VERSION_NUMBER
PROGRAM_APPLICATION_ID
PROGRAM_ID
PROGRAM_UPDATE_DATE
REQUEST_ID
ORIG_SYSTEM_REFERENCE
CUST_ACCOUNT_ID
"@ -split "`r`n"

function Remove-EBSSQLPropertiesWeDontCareAbout {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$PSObject
    )
    process {
        $PSObject.psobject.Properties |
		Where-Object { 
            $_.name -in $Script:PropertiesWeDontCareAbout          
        } |
		ForEach-Object {
			$PsObject.psobject.Properties.Remove($_.name)
        }
        $PSObject
    }
}

function Get-EBSUserNameAndResponsibility {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
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

function Get-EBSTradingCommunityArchitectureParty {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        
        [Parameter(ValueFromPipelineByPropertyName)]
        [String]$Party_ID,

        [Parameter(ValueFromPipelineByPropertyName)]
        [String]$Party_Number,

        [String]$PERSON_FIRST_NAME,
        [String]$PERSON_LAST_NAME,

        [String]$Party_Name
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
        [Parameter(ValueFromPipelineByPropertyName)]$PARTY_SITE_ID,
        [Parameter(ValueFromPipelineByPropertyName)]$Contact_Number
    )
    process {
        $SQLCommand = New-EBSSQLSelect -TableName hz_org_contacts -Parameters $PSBoundParameters
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function New-EBSSQLSelect {
    param (
        [Parameter(Mandatory)]$TableName,
        [Parameter(Mandatory)]$Parameters,
        $ArbitraryWhere,
        [String[]]$ColumnsToExclude
    )
    $ParametersToInclude = $Parameters.GetEnumerator() |
    Where-Object Name -NE "EBSEnvironmentConfiguration"

    $OFSBeforeChange = $OFS
    $OFS = ""

    $ColumnNames = Get-EBSSQLTableColumnName -TableName $TableName
    $ColumnsToInclude = $ColumnNames | 
    Where-Object { $_ -notin $ColumnsToExclude -and $_ -notin $Script:PropertiesWeDontCareAbout }

@"
select
$($ColumnsToInclude -join ",`r`n")
from
$TableName
where 1 = 1
$(
    $ParametersToInclude | New-EBSSQLWhereCondition -TableName $TableName
    $ArbitraryWhere
)
"@
    $OFS = $OFSBeforeChange
}

function New-EBSSQLWhereCondition {
    [Cmdletbinding(DefaultParameterSetName="Name")]
    param (
        [Parameter(Mandatory)]$TableName,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName,ParameterSetName="Name")]$Name,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName,ParameterSetName="Key")]$Key,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$Value
    )
    process {
        if ($Key) {$Name = $Key}
        "AND $TableName.$Name = '$Value'`r`n"
    }
}

function Get-EBSTradingCommunityArchitecturePartySite {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Parameter(Mandatory,ValueFromPipelineByPropertyName,ParameterSetName="Party_ID")]$Party_ID,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName,ParameterSetName="PARTY_SITE_NUMBER")]$PARTY_SITE_NUMBER
    )
    process {
        $SQLCommand = New-EBSSQLSelect -Parameters $PSBoundParameters -TableName HZ_PARTY_SITES 
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function Get-EBSTradingCommunityArchitectureLocation {
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Parameter(ValueFromPipelineByPropertyName)]$Location_ID,
        [Parameter(ValueFromPipelineByPropertyName)]$Address1,
        [Parameter(ValueFromPipelineByPropertyName)]$Postal_Code,
        [Parameter(ValueFromPipelineByPropertyName)]$State
    )
    process {
        $SQLCommand = New-EBSSQLSelect -TableName "hz_locations" -ColumnsToExclude GEOMETRY -Parameters $PSBoundParameters        
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
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
        [Parameter(ValueFromPipelineByPropertyName)]$object_id,
        [Parameter(ValueFromPipelineByPropertyName)]$subject_id,
        [Parameter(ValueFromPipelineByPropertyName)]$Relationship_ID
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
        
        [Parameter(Mandatory,ParameterSetName="PhoneNumber")]
        $Phone_Area_Code,
        
        [Parameter(Mandatory,ParameterSetName="PhoneNumber")]
        $Phone_Number,

        [Parameter(Mandatory,ParameterSetName="Transposed_Phone_Number")]
        $Transposed_Phone_Number,
        
        [Parameter(Mandatory,ParameterSetName="owner_table_id")]
        $owner_table_id
    )

    $ArbitraryWhere = if ($EmailAddress) {
        "AND UPPER(hz_contact_points.email_address) = UPPER('$($EmailAddress)')"
    }

    $Parameters = $PSBoundParameters | ConvertFrom-PSBoundParameters -ExcludeProperty EBSEnvironmentConfiguration, EmailAddress -AsHashTable
    $SQLCommand = New-EBSSQLSelect -TableName hz_contact_points -Parameters $Parameters -ArbitraryWhere $ArbitraryWhere
    Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
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

function Find-EBSCustomerAccountNumber {
    param (
        $Email_Address,
        $Transposed_Phone_Number,
        $Address1,
        $Postal_Code,
        $State,        
        $Person_Last_Name,
        $Party_Name,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Switch]$ReturnQueryOnly
    )

    $OriginalQueryText = Get-Content "$Script:ModulePath\SQL\Find Customer Account Number.sql"
    $Parameters = $PSBoundParameters
    
    if ($Email_Address) {
        $Parameters["Email_Address"] = $Email_Address.ToUpper()
    }
    
    if ($Party_Name) {
        $Parameters["Party_Name"] = $Party_Name.ToUpper()
    }

    if ($Person_Last_Name) {
        $Parameters["Person_Last_Name"] = $Person_Last_Name.ToUpper()
    }

    $QueryTextWithBindVariablesSubstituted = Invoke-SubstituteOracleBindVariable -Content $OriginalQueryText -Parameters $Parameters

    if ($ReturnQueryOnly) {
        $QueryTextWithBindVariablesSubstituted
    } else {
        $SQLCommand = $QueryTextWithBindVariablesSubstituted -replace ";", "" | Out-String
        Invoke-EBSSQL -SQLCommand $SQLCommand -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration |
        Select-Object -ExpandProperty Account_Number    
    }
}

function Invoke-SubstituteOracleBindVariable {
    param (
        $Parameters,
        $Content
    )
    [Regex]$Regex = "(?::)(?<BindVariableName>\w+)"
    
    $BindVariableNames = $Regex.Matches($Content).Groups |
    Where-Object Name -eq BindVariableName |
    Select-Object -ExpandProperty Value |
    Sort-Object -Unique

    foreach ($BindVariableName in $BindVariableNames) {
        $ParameterValue = $Parameters[$BindVariableName]

        if ($ParameterValue.count -gt 1) {
            $ValueFormatted = $ParameterValue | ForEach-Object { 
                "'$_'"
            }
            $ValueFormatted = "($($ValueFormatted -join ","))"
            $Content = $Content.replace("= :$BindVariableName", "in $ValueFormatted")
            $Content = $Content.replace(":$BindVariableName IS NULL", "NOT NULL IS NULL")
        } else {
            $ValueFormatted = if ($ParameterValue) { 
                "'$ParameterValue'"
            } else {
                "NULL"
            }
            $Content = $Content.replace(":$BindVariableName", $ValueFormatted)
        }
    }
    $Content
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
    Add-Member -PassThru -MemberType ScriptProperty -Name ContactPoint -Value {
        Get-EBSTradingCommunityArchitectureContactPoint -owner_table_id $This.PARTY_ID
    }
}

function Get-EBSTradingCommunityArchitectureCustomerAccountObject {
    param (
        [Parameter(Mandatory)]$Party_ID
    )
    Get-EBSTradingCommunityArchitectureCustomerAccount -Party_ID $PARTY_ID |
    Add-Member -MemberType ScriptProperty -Name Site -PassThru -Value {
        Get-EBSTradingCommunityArchitectureSiteObject -Party_ID $This.PARTY_ID
    } |
    Add-Member -MemberType ScriptProperty -Name Contact -PassThru -Value {
        Get-EBSTradingCommunityArchitectureRelationship -object_id $This.Party_ID |
        foreach {
            Get-EBSTradingCommunityArchitectureContactObject -party_relationship_id $_.RELATIONSHIP_ID |
            where {-not $_.Party_Site_ID }
        }        
    }
}

function Get-EBSTradingCommunityArchitectureSiteObject {
    param (
        [Parameter(Mandatory)]$Party_ID
    )
    Get-EBSTradingCommunityArchitecturePartySite -Party_ID $PARTY_ID |
    Add-Member -MemberType ScriptProperty -PassThru -Name Contact -Value {        
        Get-EBSTradingCommunityArchitectureContactObject -PARTY_SITE_ID $This.Party_Site_ID
    } |
    Add-Member -PassThru -MemberType ScriptProperty -Name ContactPoint -Value {
        Get-EBSTradingCommunityArchitectureContactPoint -owner_table_id $This.PARTY_SITE_ID
    } |
    Add-Member -PassThru -MemberType ScriptProperty -Name Location -Value {
        Get-EBSTradingCommunityArchitectureLocation -Location_ID $This.Location_ID
    }
}

function Get-EBSTradingCommunityArchitectureContactObject {
    param (
        [Parameter(Mandatory,ParameterSetName = "PARTY_SITE_ID")]$PARTY_SITE_ID,
        [Parameter(Mandatory,ParameterSetName = "party_relationship_id")]$party_relationship_id
    )
    Get-EBSTradingCommunityArchitectureOrganiztaionContact @PSBoundParameters |
    Add-Member -PassThru -MemberType ScriptProperty -Name PartyRelationship -Value {
        Get-EBSTradingCommunityArchitectureRelationship -Relationship_ID $this.PARTY_RELATIONSHIP_ID |
        Where-Object SUBJECT_TYPE -eq "PERSON"
    } |
    Add-Member -PassThru -MemberType ScriptProperty -Name ContactPoint -Value {
        Get-EBSTradingCommunityArchitectureContactPoint -owner_table_id $This.PartyRelationship.PARTY_ID
    } |
    Add-Member -PassThru -MemberType ScriptProperty -Name Site -Value {
        Get-EBSTradingCommunityArchitectureSiteObject -Party_ID $This.PartyRelationship.PARTY_ID
    } 
}

function EBSTradingCommunityArchitectureOrganizationLogicalObject {
    param (
        [Parameter(Mandatory)]$Party_ID
    )
    $OrganizationObject = Get-EBSTradingCommunityArchitectureOrganizationObject @PSBoundParameters

    $OrganizationObject | Select-Object -Property 
}

function Get-EBSMaterialItem{
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Parameter(ValueFromPipelineByPropertyName)][String]$Inventory_Item_ID,
        [Parameter(ValueFromPipelineByPropertyName)][Int]$Organization_ID
    )
    process {
        $SQLCommand = New-EBSSQLSelect -Parameters $PSBoundParameters -TableName MTL_SYSTEM_ITEMS_B
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function Get-EBSMaterialCrossReference{
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [String]$Cross_Reference,
        [Int]$Organization_ID
    )
    process {
        $SQLCommand = New-EBSSQLSelect -Parameters $PSBoundParameters -TableName MTL_CROSS_REFERENCES_B
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function Find-EBSItem{
    param (
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [String]$Cross_Reference,
        [Int]$Organization_ID
    )
    Get-EBSMaterialCrossReference -Cross_Reference $Cross_Reference |
    Get-EBSMaterialItem -Organization_ID $Organization_ID
}

function ConvertTo-OracleSQLArraysSplitByItemIncrement {
    param(
        [parameter(Mandatory, ValueFromPipeline)][PSCustomObject]$CSVObject,
        [parameter(Mandatory)][String]$ColumnName,
        [parameter()]$Increment = 1000
    )

    $ItemArray = $CSVObject | Select-Object -Property $ColumnName

    For ($i=0; $i -LT $ItemArray.length; $i += $Increment) {
        $Selection = $ItemArray | Select -First $Increment -Skip $i 
        ConvertTo-SQLArrayFromCSV -CSVObject $Selection -CSVColumnName $ColumnName
    
    }
}

function New-OracleSQLInQueryArray {
    param (
        [Parameter(Mandatory)]$ColumnName,
        [Parameter(Mandatory)]$CSVPath
    )
    $CSVObject = Import-Csv -Path $CSVPath
    $LookupSets = ConvertTo-OracleSQLArraysSplitByItemIncrement -ColumnName $ColumnName -CSVObject $CSVObject
    
    $Query = @"
SELECT
    item_number, organization_code
FROM 
    apps.xxtrvs_bt_items_stg
WHERE
    organization_code <> 'STO' AND item_number IN

"@

    for ($i = 0; $i -lt $LookupSets.Count -1; $i++) {
        
        $Query += @"
    $($LookupSets[$i]) OR item_number IN

"@
    }

    $Query += @"
    $($LookupSets[$LookupSets.Count - 1])
"@
    $Query
}

function Invoke-LocalSQLPlusQueryAsSysDBA{
    param(
        [parameter(Mandatory)]$Command,
        [parameter(Mandatory)]$SSHSession
    )
    $Whoami = (Invoke-SSHCommand -SSHSession $SshSession -Command "whoami").output
    If($Whoami -eq "oracle"){
        $SQLPlusCommand = @"
sqlplus "/ as sysdba" <<EOF
$Command
quit;
EOF
"@
    }
    else{
        Write-Error "SSHSession not Oracle user" -Category InvalidOperation -ErrorAction Stop
    }
}

function Get-EBSTradingCommunityArchitectureListHeaders {
    param (
        [parameter(ValueFromPipelineByPropertyName)]$Name,
        [parameter(ValueFromPipelineByPropertyName)]$Description,
        [parameter(ValueFromPipelineByPropertyName)]$list_type_code,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    process {
        $SQLCommand = New-EBSSQLSelect -Parameters $PSBoundParameters -TableName "qp_list_headers_all"
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}


function Get-EBSTradingCommunityArchitectureTransactionTypesTL {
    param (
        [parameter(ValueFromPipelineByPropertyName)]$Transaction_Type_ID,
        [parameter(ValueFromPipelineByPropertyName)]$Name,
        [parameter(ValueFromPipelineByPropertyName)]$Description,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    process {
        $SQLCommand = New-EBSSQLSelect -Parameters $PSBoundParameters -TableName "oe_transaction_types_tl"
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function Get-EBSCustomerClassSalesRepName {
    param (
        [parameter(mandatory)]$FirstName,
        [parameter(mandatory)]$LastName,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration),
        [Switch]$ReturnQueryOnly
    )

    $OriginalQueryText = Get-Content "$Script:ModulePath\SQL\Get-CustomerClassLookupCode.sql"
    $Parameters = $PSBoundParameters
    $SalesRepName = "$LastName, $FirstName".ToUpper()
    
    $QueryTextWithBindVariablesSubstituted = Invoke-SubstituteOracleBindVariable -Content $OriginalQueryText -Parameters $SalesRepName

    if ($ReturnQueryOnly) {
        $QueryTextWithBindVariablesSubstituted
    } else {
        $SQLCommand = $QueryTextWithBindVariablesSubstituted -replace ";", "" | Out-String
        Invoke-EBSSQL -SQLCommand $SQLCommand -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration 
    }
}

function Get-EBSTradingCommunityArchitectureARLookup {
    param (
        [parameter(ValueFromPipelineByPropertyName)]$Lookup_Type,
        [parameter(ValueFromPipelineByPropertyName)]$Lookup_Code,
        [parameter(ValueFromPipelineByPropertyName)]$Meaning,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    process {
        $SQLCommand = New-EBSSQLSelect -Parameters $PSBoundParameters -TableName "ar_lookups"
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function Get-EBSTradingCommunityArchitectureSalesRep {
    param (
        [parameter(ValueFromPipelineByPropertyName)]$Name,
        [parameter(ValueFromPipelineByPropertyName)]$SalesRep_ID,
        [parameter(ValueFromPipelineByPropertyName)]$Resource_ID,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    process {
        $SQLCommand = New-EBSSQLSelect -Parameters $PSBoundParameters -TableName "JTF_RS_SALESREPS"
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function Get-EBSTradingCommunityArchitectureFNDLookupValues {
    param (
        [parameter(ValueFromPipelineByPropertyName)]$Lookup_Type,
        [parameter(ValueFromPipelineByPropertyName)]$View_Application_ID,
        [parameter(ValueFromPipelineByPropertyName)]$Lookup_Code,
        [parameter(ValueFromPipelineByPropertyName)]$Security_Group_ID,
        [parameter(ValueFromPipelineByPropertyName)]$Meaning,
        [parameter(ValueFromPipelineByPropertyName)]$Language,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    process {
        $SQLCommand = New-EBSSQLSelect -Parameters $PSBoundParameters -TableName "fnd_lookup_values"
        Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
    }
}

function Invoke-HZCustAccountV2PubCreateCustAccount{
    param(
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$organization_name,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$created_by_module,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$account_name,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$p_account_number,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$customer_type,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$customer_class_code,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$fob_point,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$freight_term,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$sales_channel_code,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$price_list_id,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$ship_via,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$SHIP_SETS_INCLUDE_LINES_FLAG,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$attribute9,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    $SQLCommand = @"
    DECLARE
    l_cust_account_rec     HZ_CUST_ACCOUNT_V2PUB.CUST_ACCOUNT_REC_TYPE;
    l_organization_rec     HZ_PARTY_V2PUB.ORGANIZATION_REC_TYPE;
    l_customer_profile_rec HZ_CUSTOMER_PROFILE_V2PUB.CUSTOMER_PROFILE_REC_TYPE;
    l_cust_profile_rec      hz_customer_profile_v2pub.customer_profile_rec_type;
    BEGIN
        l_organization_rec.organization_name := '$($organization_name)';
        l_organization_rec.created_by_module := '$($created_by_module)';
        l_cust_account_rec.account_name := '$($account_name)';
        l_cust_account_rec.created_by_module := '$($created_by_module)';
        l_cust_account_rec.account_number := '$($p_account_number)';
        l_cust_account_rec.customer_type       :=  '$($customer_type)';
        l_cust_account_rec.customer_class_code :=  '$($customer_class_code)';
        l_cust_account_rec.fob_point           :=  '$($fob_point)';
        l_cust_account_rec.freight_term        :=  '$($freight_term)';
        l_cust_account_rec.sales_channel_code  :=  '$($sales_channel_code)';
        l_cust_account_rec.price_list_id       :=  '$($price_list_id)';
        l_cust_account_rec.ship_via            :=  '$($ship_via)';
        l_cust_account_rec.SHIP_SETS_INCLUDE_LINES_FLAG := '$($SHIP_SETS_INCLUDE_LINES_FLAG)';
        l_cust_account_rec.attribute9          :=  '$($attribute9)';
            hz_cust_account_v2pub.create_cust_account(
                p_init_msg_list          => Fnd_Api.g_true,
                p_cust_account_rec       => l_cust_account_rec,
                p_organization_rec       => l_organization_rec,
                p_customer_profile_rec   => l_cust_profile_rec,
                x_cust_account_id        => :x_cust_account_id,
                x_account_number         => :x_account_number,
                x_party_id               => :x_party_id,
                x_party_number           => :x_party_number,
                x_profile_id             => :x_cust_profile_id,
                x_return_status          => :x_return_status,
                x_msg_count              => :x_msg_count,
                x_msg_data               => :x_msg_data);
    END;
"@
    $OracleParameters = $(
        $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
            ParameterName = "x_cust_account_id"
            OracleDBType = "INT32"
            Direction = "Output"
        }),
        $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
            ParameterName = "x_account_number"
            OracleDBType = "VARCHAR2"
            Size = 200
            Direction = "Output"
        }),
        $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
            ParameterName = "x_party_id"
            OracleDBType = "INT32"
            Direction = "Output"
        }),
        $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
            ParameterName = "x_party_number"
            OracleDBType = "VARCHAR2"
            Size = 2000
            Direction = "Output"
        }),
        $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
            ParameterName = "x_cust_profile_id"
            OracleDBType = "INT32"
            Direction = "Output"
        }),
        $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
            ParameterName = "x_return_status"
            OracleDBType = "VARCHAR2"
            Size = 2000
            Direction = "Output"
        }),
        $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
            ParameterName = "x_msg_count"
            OracleDBType = "INT32"
            Direction = "Output"
        }),
        $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
            ParameterName = "x_msg_data"
            OracleDBType = "VARCHAR2"
            Size = 2000
            Direction = "Output"
        }))

    Invoke-OracleSQLWithParameters -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -OracleParameters $OracleParameters | Out-Null

    $Output = [PSCustomObject]@{}
    ForEach($OutputParameter in ($OracleParameters | where {$_.Direction -eq "output"})){
            $Output | Add-Member -MemberType NoteProperty -Name $OutputParameter.Parametername -Value $OutputParameter.value.value
    }
    $Output
}

function Invoke-HZLocationV2PubCreateLocation{
    param(
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$country,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$address1,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$address2,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$address3,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$city,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$postal_code,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$state,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$province,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$created_by_module,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)

    )
    Process{
        $SQLCommand = @"
        DECLARE
                p_location_rec  HZ_LOCATION_V2PUB.LOCATION_REC_TYPE;
        BEGIN
                p_location_rec.created_by_module := '$($created_by_module)';
                p_location_rec.country := '$($country)';
                p_location_rec.address1 := '$($address1)';
                p_location_rec.address2 := '$($address2)';
                p_location_rec.address3 := '$($address3)';
                p_location_rec.city    := '$($city)';
                p_location_rec.postal_code := '$($postal_code)';
                p_location_rec.state := '$($state)';
                p_location_rec.province := '$($province)';
                hz_location_v2pub.create_location(
                        p_init_msg_list     => 'T',
                        p_location_rec      => p_location_rec,
                        x_location_id       => :x_location_id,
                        x_return_status     => :x_return_status,
                        x_msg_count         => :x_msg_count,
                        x_msg_data          => :x_msg_data);
        END;
"@
        $OracleParameters = $(
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_location_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_return_status"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_count"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_data"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }))
        Invoke-OracleSQLWithParameters -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -OracleParameters $OracleParameters | Out-Null

        $Output = [PSCustomObject]@{}
        ForEach($OutputParameter in ($OracleParameters | where {$_.Direction -eq "output"})){
                $Output | Add-Member -MemberType NoteProperty -Name $OutputParameter.Parametername -Value $OutputParameter.value.value
        }
        $Output
    }
}

function Invoke-HZPartySiteV2PubCreatePartySite{
    param(
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$party_id,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$location_id,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$identifying_address_flag,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$created_by_module,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)

    )
    Process{
        $SQLCommand = @"
        DECLARE
        p_party_site_rec    HZ_PARTY_SITE_V2PUB.PARTY_SITE_REC_TYPE;
        BEGIN
        p_party_site_rec.party_id := '$($party_id)';
        p_party_site_rec.location_id := '$($location_id)';
        p_party_site_rec.identifying_address_flag := '$($identifying_address_flag)';
        p_party_site_rec.created_by_module := '$($created_by_module)';
         hz_party_site_v2pub.create_party_site(
          'T',
          p_party_site_rec,
          :x_party_site_id,
          :x_party_site_number,
          :x_return_status,
          :x_msg_count,
          :x_msg_data);
        END;
"@
        $OracleParameters = $(
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_party_site_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_party_site_number"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_return_status"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_count"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_data"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }))
        Invoke-OracleSQLWithParameters -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -OracleParameters $OracleParameters | Out-Null

        $Output = [PSCustomObject]@{}
        ForEach($OutputParameter in ($OracleParameters | where {$_.Direction -eq "output"})){
                $Output | Add-Member -MemberType NoteProperty -Name $OutputParameter.Parametername -Value $OutputParameter.value.value
        }
        $Output
    }
}

function Invoke-HZCustAccountSiteV2PubCreateCustAcctSite{
    param(
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$cust_acct_id,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$party_site_id,
        [parameter(ValueFromPipelineByPropertyName)]$Language = "US",
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$created_by_module,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$FNDUserID,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)

    )
    Process{
        $SQLCommand = @"
        DECLARE`
        p_cust_acct_site_rec    hz_cust_account_site_v2pub.cust_acct_site_rec_type;
        org_id    NUMBER := 82;
        BEGIN
        p_cust_acct_site_rec.cust_account_id := '$($cust_acct_id)'; --lx_cust_acct_id;--12722; 
        p_cust_acct_site_rec.party_site_id := '$($PARTY_SITE_ID)'; --l_bparty_site_id;--12164;
        fnd_global.apps_initialize ( user_id      => $($FNDUserID)
                                   ,resp_id      => 21623
                                   ,resp_appl_id => 660);
        mo_global.init ( 'AR' ) ;
        mo_global.set_policy_context ('S', org_id ) ;
        p_cust_acct_site_rec.org_id := org_id;
        p_cust_acct_site_rec.created_by_module := '$($created_by_module)';
        hz_cust_account_site_v2pub.create_cust_acct_site(
            'T',
            p_cust_acct_site_rec,
            :x_cust_acct_site_id,
            :x_return_status,
            :x_msg_count,
            :x_msg_data);
        END;
"@
        $OracleParameters = $(
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_cust_acct_site_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_return_status"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_count"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_data"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }))
        Invoke-OracleSQLWithParameters -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -OracleParameters $OracleParameters | Out-Null

        $Output = [PSCustomObject]@{}
        ForEach($OutputParameter in ($OracleParameters | where {$_.Direction -eq "output"})){
                $Output | Add-Member -MemberType NoteProperty -Name $OutputParameter.Parametername -Value $OutputParameter.value.value
        }
        $Output
    }
}


function New-OracleManagedDataAccessParameter{
    param(
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$ParameterName,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$Direction,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$OracleDbType,
        [parameter(ValueFromPipelineByPropertyName)]$Size,
        [parameter(ValueFromPipelineByPropertyName)]$Value
    )
    process{
        New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
            ParameterName = $ParameterName;
            OracleDbType = $OracleDbType
            Direction = $Direction;
            Size = $Size;
            Value = $Value
        }
    }
}


function Invoke-HZCustAccountSiteV2PubCreateCustSiteUse{
    param(
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$cust_acct_site_id,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$site_use_code,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$primary_salesrep_id,
        [parameter(ValueFromPipelineByPropertyName)]$order_type_id,
        [parameter(ValueFromPipelineByPropertyName)]$price_list_id,
        [parameter(ValueFromPipelineByPropertyName)]$fob_point,
        [parameter(ValueFromPipelineByPropertyName)]$freight_term,
        [parameter(ValueFromPipelineByPropertyName)]$ship_via,
        [parameter(ValueFromPipelineByPropertyName)]$SHIP_SETS_INCLUDE_LINES_FLAG,
        [parameter(ValueFromPipelineByPropertyName)]$attribute9,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$created_by_module,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)

    )
    Process{
        $SQLCommand = @"
        DECLARE
        p_cust_site_use_rec HZ_CUST_ACCOUNT_SITE_V2PUB.CUST_SITE_USE_REC_TYPE;
        p_customer_profile_rec HZ_CUSTOMER_PROFILE_V2PUB.CUSTOMER_PROFILE_REC_TYPE;
        BEGIN
        p_cust_site_use_rec.cust_acct_site_id := '$($cust_acct_site_id)'; 
        p_cust_site_use_rec.site_use_code := '$($site_use_code)';
        p_cust_site_use_rec.primary_salesrep_id := '$($primary_salesrep_id)';
        p_cust_site_use_rec.order_type_id := '$($order_type_id)';
        p_cust_site_use_rec.price_list_id := '$($price_list_id)';
        p_cust_site_use_rec.fob_point           :=  '$($fob_point)';
        p_cust_site_use_rec.freight_term        :=  '$($freight_term)';
        p_cust_site_use_rec.ship_via            :=  '$($ship_via)';
        p_cust_site_use_rec.SHIP_SETS_INCLUDE_LINES_FLAG := '$($SHIP_SETS_INCLUDE_LINES_FLAG)';
        p_cust_site_use_rec.attribute9          :=  '$($attribute9)' ;
        p_cust_site_use_rec.created_by_module := '$($created_by_module)';
        hz_cust_account_site_v2pub.create_cust_site_use(
            'T',
            p_cust_site_use_rec,
            p_customer_profile_rec,
            '',
            '',
            :x_site_use_id,
            :x_return_status,
            :x_msg_count,
            :x_msg_data);
    END;
"@
        $OracleParameters = $(
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_site_use_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_return_status"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_count"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_data"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }))
        Invoke-OracleSQLWithParameters -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -OracleParameters $OracleParameters | Out-Null

        $Output = [PSCustomObject]@{}
        ForEach($OutputParameter in ($OracleParameters | where {$_.Direction -eq "output"})){
                $Output | Add-Member -MemberType NoteProperty -Name $OutputParameter.Parametername -Value $OutputParameter.value.value
        }
        $Output
    }
}

function Invoke-HZPartyV2PubCreatePerson{
    param(
        [parameter(ValueFromPipelineByPropertyName)]$person_pre_name_adjunct,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$person_first_name,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$person_last_name,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$created_by_module,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)

    )
    Process{
        $SQLCommand = @"
        DECLARE
        p_person_rec HZ_PARTY_V2PUB.person_rec_type;
        BEGIN
        p_person_rec.person_pre_name_adjunct := '$($person_pre_name_adjunct)';
        p_person_rec.person_first_name := '$($person_first_name)';
        p_person_rec.person_last_name := '$($person_last_name)';
        p_person_rec.created_by_module := '$($created_by_module)';
       
        HZ_PARTY_V2PUB.create_person(
        'T',
        p_person_rec,
        :x_bparty_id,
        :x_bparty_number,
        :x_bprofile_id,
        :x_return_status,
        :x_msg_count,
        :x_msg_data);
        END;
"@
        $OracleParameters = $(
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_party_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_party_number"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_profile_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_return_status"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_count"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_data"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }))
        Invoke-OracleSQLWithParameters -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -OracleParameters $OracleParameters | Out-Null

        $Output = [PSCustomObject]@{}
        ForEach($OutputParameter in ($OracleParameters | where {$_.Direction -eq "output"})){
                $Output | Add-Member -MemberType NoteProperty -Name $OutputParameter.Parametername -Value $OutputParameter.value.value
        }
        $Output
    }
}

function Invoke-HZPartyContactV2PubCreateOrgContact{
    param(
        [parameter(ValueFromPipelineByPropertyName)]$subject_id,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$object_id,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$subject_type,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$subject_table_name,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$object_type,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$object_table_name,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$relationship_code,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$relationship_type,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$created_by_module,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)

    )
    Process{
        $SQLCommand = @"
        DECLARE
        p_org_contact_rec HZ_PARTY_CONTACT_V2PUB.ORG_CONTACT_REC_TYPE;
        BEGIN
        p_org_contact_rec.created_by_module := '$($created_by_module)';
        p_org_contact_rec.party_rel_rec.subject_id := '$($subject_id)';
        p_org_contact_rec.party_rel_rec.subject_type := '$($subject_type)';
        p_org_contact_rec.party_rel_rec.subject_table_name := '$($subject_table_name)';
        p_org_contact_rec.party_rel_rec.object_id := '$($object_id)';
        p_org_contact_rec.party_rel_rec.object_type := '$($object_type)';
        p_org_contact_rec.party_rel_rec.object_table_name := '$($object_table_name)';
        p_org_contact_rec.party_rel_rec.relationship_code := '$($relationship_code)';
        p_org_contact_rec.party_rel_rec.relationship_type := '$($relationship_type)';
        p_org_contact_rec.party_rel_rec.start_date := SYSDATE;

        hz_party_contact_v2pub.create_org_contact(
        'T',
        p_org_contact_rec,
        :x_org_contact_id,
        :x_party_rel_id,
        :x_party_id,
        :x_party_number,
        :x_return_status,
        :x_msg_count,
        :x_msg_data);
        END;
"@
        $OracleParameters = $(
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_org_contact_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_party_rel_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_party_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_party_number"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_return_status"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_count"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_data"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }))
        Invoke-OracleSQLWithParameters -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -OracleParameters $OracleParameters | Out-Null

        $Output = [PSCustomObject]@{}
        ForEach($OutputParameter in ($OracleParameters | where {$_.Direction -eq "output"})){
                $Output | Add-Member -MemberType NoteProperty -Name $OutputParameter.Parametername -Value $OutputParameter.value.value
        }
        $Output
    }
}

function Invoke-HZCustAccountRoleV2PubCreateCustAccountRole{
    param(
        [parameter(ValueFromPipelineByPropertyName)]$party_id,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$cust_account_id,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$cust_acct_site_id,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$primary_flag,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$role_type,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$created_by_module,
        [parameter(mandatory,ValueFromPipelineByPropertyName)]$FNDUserID,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)

    )
    Process{
        $SQLCommand = @"
        DECLARE
        p_cust_account_role_rec HZ_CUST_ACCOUNT_ROLE_V2PUB.cust_account_role_rec_type;
        org_id    NUMBER := 82;
        BEGIN
        fnd_global.apps_initialize ( user_id      => $($FNDUserID)
        ,resp_id      => 21623
        ,resp_appl_id => 660);
        mo_global.init ( 'AR' ) ;
        mo_global.set_policy_context ('S', org_id ) ;

        p_cust_account_role_rec.party_id := '$($party_id)';--11339; 
        p_cust_account_role_rec.cust_account_id := '$($cust_account_id)';--10033; 
        p_cust_account_role_rec.cust_acct_site_id := '$($cust_acct_site_id)';
        p_cust_account_role_rec.primary_flag := '$($primary_flag)';
        p_cust_account_role_rec.role_type := '$($role_type)';
        p_cust_account_role_rec.created_by_module := '$($created_by_module)';
        
        HZ_CUST_ACCOUNT_ROLE_V2PUB.create_cust_account_role(
        'T',
        p_cust_account_role_rec,
        :x_cust_account_role_id,
        :x_return_status,
        :x_msg_count,
        :x_msg_data);
        END;
"@
        $OracleParameters = $(
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_cust_account_role_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_return_status"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_count"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_data"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }))
        Invoke-OracleSQLWithParameters -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -OracleParameters $OracleParameters | Out-Null

        $Output = [PSCustomObject]@{}
        ForEach($OutputParameter in ($OracleParameters | where {$_.Direction -eq "output"})){
                $Output | Add-Member -MemberType NoteProperty -Name $OutputParameter.Parametername -Value $OutputParameter.value.value
        }
        $Output
    }
}

function Invoke-HZContactPointV2PubCreateContactPoint{
    param(
        [parameter(ValueFromPipelineByPropertyName)]$party_id,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$owner_table_name,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$owner_table_id,
        [parameter(ValueFromPipelineByPropertyName)]$contact_point_type,
        [parameter(ValueFromPipelineByPropertyName)]$phone_line_type,
        [parameter(ValueFromPipelineByPropertyName)]$phone_area_code,
        [parameter(ValueFromPipelineByPropertyName)]$Phone_number,
        [parameter(ValueFromPipelineByPropertyName)]$email_format,
        [parameter(ValueFromPipelineByPropertyName)]$email_address,
        [parameter(ValueFromPipelineByPropertyName)]$created_by_module,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    Process{
        $SQLCommand = @"
        DECLARE
        p_contact_point_rec HZ_CONTACT_POINT_V2PUB.CONTACT_POINT_REC_TYPE;
        p_phone_rec HZ_CONTACT_POINT_V2PUB.phone_rec_type;
        p_edi_rec HZ_CONTACT_POINT_V2PUB.edi_rec_type;
        p_telex_rec HZ_CONTACT_POINT_V2PUB.telex_rec_type;
        p_web_rec HZ_CONTACT_POINT_V2PUB.web_rec_type;
        p_email_rec HZ_CONTACT_POINT_V2PUB.email_rec_type;
        BEGIN
        p_contact_point_rec.created_by_module :=  '$($created_by_module)';
        p_contact_point_rec.owner_table_name := '$($owner_table_name)';
        p_contact_point_rec.owner_table_id :=  '$($owner_table_id)';
        p_contact_point_rec.contact_point_type := '$($contact_point_type)';
        p_phone_rec.phone_line_type := '$($phone_line_type)';
        p_phone_rec.phone_area_code := '$($phone_area_code)'; --substr(p_bphone_number,1,3);--p_phone_area_code;--'407';
        p_phone_rec.Phone_number := '$($Phone_number)'; --substr(p_bphone_number,5);
        p_email_rec.email_format := '$($email_format)';
        p_email_rec.email_address := '$($email_address)';
    HZ_CONTACT_POINT_V2PUB.create_contact_point (
      'T',
      p_contact_point_rec,
      p_edi_rec,
      p_email_rec,
      p_phone_rec,
      p_telex_rec,
      p_web_rec,
      :x_contact_point_id,
      :x_return_status,
      :x_msg_count,
      :x_msg_data);
      END;
"@
        $OracleParameters = $(
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_contact_point_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_return_status"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_count"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_data"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }))
        Invoke-OracleSQLWithParameters -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -OracleParameters $OracleParameters | Out-Null

        $Output = [PSCustomObject]@{}
        ForEach($OutputParameter in ($OracleParameters | where {$_.Direction -eq "output"})){
                $Output | Add-Member -MemberType NoteProperty -Name $OutputParameter.Parametername -Value $OutputParameter.value.value
        }
        $Output
    }
}

function Invoke-HZCustAccountRoleV2PubCreateRoleResponsibility{
    param(
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$cust_account_role_id,
        [parameter(Mandatory,ValueFromPipelineByPropertyName)]$responsibility_type,
        [parameter(ValueFromPipelineByPropertyName)]$created_by_module,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    Process{
        $SQLCommand = @"
        DECLARE
        p_role_responsibility_rec HZ_CUST_ACCOUNT_ROLE_V2PUB.ROLE_RESPONSIBILITY_REC_TYPE;
        BEGIN
        p_role_responsibility_rec.cust_account_role_id := '$($cust_account_role_id)';
        p_role_responsibility_rec.responsibility_type := '$($responsibility_type)';
        p_role_responsibility_rec.created_by_module := '$($created_by_module)';
        
        HZ_CUST_ACCOUNT_ROLE_V2PUB.create_role_responsibility (
        'T',
        p_role_responsibility_rec,
        :x_responsibility_id,
        :x_return_status,
        :x_msg_count,
        :x_msg_data
        );
        END;
"@
        $OracleParameters = $(
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_responsibility_id"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_return_status"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_count"
                    OracleDBType = "INT32"
                    Direction = "Output"
            }),
            $(New-Object -TypeName Oracle.ManagedDataAccess.Client.OracleParameter -Property @{
                    ParameterName = "x_msg_data"
                    OracleDBType = "VARCHAR2"
                    Size = 2000
                    Direction = "Output"
            }))
        Invoke-OracleSQLWithParameters -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -OracleParameters $OracleParameters | Out-Null

        $Output = [PSCustomObject]@{}
        ForEach($OutputParameter in ($OracleParameters | where {$_.Direction -eq "output"})){
                $Output | Add-Member -MemberType NoteProperty -Name $OutputParameter.Parametername -Value $OutputParameter.value.value
        }
        $Output
    }
}

function Get-EBSFNDUser {
    param (
        [parameter(mandatory)]$user_name,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )
    $SQLCommand = New-EBSSQLSelect -Parameters $PSBoundParameters -TableName "fnd_user"
    Invoke-EBSSQL -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration -SQLCommand $SQLCommand
}
