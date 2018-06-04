$ModulePath = (Get-Module -ListAvailable OracleE-BusinessSuitePowerShell).ModuleBase

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
    if ($EBSEnvironmentConfiguration) {
        Invoke-OracleSQL -ConnectionString $EBSEnvironmentConfiguration.DatabaseConnectionString -SQLCommand $SQLCommand -ConvertFromDataRow |
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
        
        [Parameter(ValueFromPipelineByPropertyName)]
        [String]$Party_ID,

        [Parameter(ValueFromPipelineByPropertyName)]
        [String]$Party_Number,

        [String]$PERSON_FIRST_NAME,
        [String]$PERSON_LAST_NAME
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
        $Person_First_Name,
        $Person_Last_Name,
        $EBSEnvironmentConfiguration = (Get-EBSPowershellConfiguration)
    )

    $OriginalQueryText = Get-Content "$Script:ModulePath\SQL\Find Customer Account Number.sql"
    $Parameters = $PSBoundParameters
    
    if ($Email_Address) {
        $Parameters.Remove("Email_Address") | Out-Null
        $Parameters.add("Email_Address", $Email_Address.ToUpper())
    }

    $QueryTextWithBindVariablesSubstituted = Invoke-SubstituteOracleBindVariable -Content $OriginalQueryText -Parameters $Parameters

    $SQLCommand = $QueryTextWithBindVariablesSubstituted -replace ";", "" | Out-String
    Invoke-EBSSQL -SQLCommand $SQLCommand -EBSEnvironmentConfiguration $EBSEnvironmentConfiguration |
    Select-Object -ExpandProperty Account_Number
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