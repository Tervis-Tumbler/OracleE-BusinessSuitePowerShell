ipmo -Force OracleE-BusinessSuitePowerShell, TervisOracleE-BusinessSuitePowerShell, InvokeSQL

Describe "OracleE-BusinessSuitePowerShell" {
    It "New-EBSSQLWhereCondition" {
        $OFSBeforeChange = $OFS
        $OFS = ""

        $Parameters = [ordered]@{ 
            Thing = "Value"
            Thing2 = "Value2"
        }
        
        $WhereCondition = $Parameters.GetEnumerator() | 
        New-EBSSQLWhereCondition -TableName TableName

        "$($WhereCondition)" | should -Be @"
AND TableName.Thing = 'Value'
AND TableName.Thing2 = 'Value2'

"@
        $OFS = $OFSBeforeChange
    }

    It "New-EBSSQLSelect" {
        Mock Get-EBSSQLTableColumnName {
            return @"
Column1
Column2
Column3
"@ -split "`r`n"
        } -ModuleName OracleE-BusinessSuitePowerShell

        $Parameters = [ordered]@{ 
            Thing = "Value"
            Thing2 = "Value2"
        }
        
        $SelectStatement = New-EBSSQLSelect -TableName TableName -Parameters $Parameters -ColumnsToExclude Column2
        $SelectStatement | should -Be @"
select
Column1,
Column3
from
TableName
where 1 = 1
AND TableName.Thing = 'Value'
AND TableName.Thing2 = 'Value2'

"@
    }
}

Describe "OracleE-BusinessSuitePowerShell Find-CustomerAccountNumber" {
    $BadPhoneAreaCode = "000"
    $BadPhoneNumber = "555-0000"
    $BadEmailAddress = "org@0000.com"

    Context "Search via Phone Number and Email Address" {
        $OrganizationPhoneAreaCode = "941"
        $OrganizationPhoneNumber = "555-1111"
        $OrganizationEmailAddress = "org@25496989.com"

        It "Organization > Communication > Phone Number" {
            $AccountNumber = Find-CustomerAccountNumber -Phone_Area_Code $OrganizationPhoneAreaCode -Phone_Number $OrganizationPhoneNumber
            $AccountNumber | Should -Be 25496989
        }

        It "Organization > Communication > Phone Number that doesn't exist" {
            $AccountNumber = Find-CustomerAccountNumber -Phone_Area_Code $BadPhoneAreaCode -Phone_Number $BadPhoneNumber
            $AccountNumber | Should -BeNullOrEmpty
        }
        
        It "Organization > Communication > Email Address" {
            $AccountNumber = Find-CustomerAccountNumber -Email_Address $OrganizationEmailAddress
            $AccountNumber | Should -Be 25496989
        }

        It "Organization > Communication > Email Address that doesn't exist" {
            $AccountNumber = Find-CustomerAccountNumber -Email_Address $BadEmailAddress
            $AccountNumber | Should -BeNullOrEmpty
        }

        It "Organization > Communication > Phone number and Email Address" {
            $AccountNumber = Find-CustomerAccountNumber -Phone_Area_Code $OrganizationPhoneAreaCode -Phone_Number $OrganizationPhoneNumber -Email_Address $OrganizationEmailAddress
            $AccountNumber | Should -Be 25496989
        }

        It "Organization > Communication > Phone number doesn't exist but Email Address does" {
            $AccountNumber = Find-CustomerAccountNumber -Phone_Area_Code $BadPhoneAreaCode -Phone_Number $BadPhoneNumber -Email_Address $OrganizationEmailAddress
            $AccountNumber | Should -BeNullOrEmpty
        }

        It "Organization > Communication > Phone number but Email Address doesn't exist" {
            $AccountNumber = Find-CustomerAccountNumber -Phone_Area_Code $OrganizationPhoneAreaCode -Phone_Number $OrganizationPhoneNumber -Email_Address $BadEmailAddress
            $AccountNumber | Should -BeNullOrEmpty
        }

        It "Organization > Party Relationships [Person] > Communication" {

        }

        It "Organization > Account > Communication > Contact" {

        }

        It "Organization > Account > Site > Communication > Contact" {

        }

        It "Organization > Account > Site > Communication" {

        }
    }

    Context "Search via Address1, Postal_Code, City" {
        It "Organization > Account > Communication > Contact > Contact Addresses > Location" {

        }

        It "Organization > Account > Site > Communication > Contact > Colntact Addresses > Location" {

        }

        It "Organization > Account > Site > Location" {

        }
    }

    Context "Search via Person_First_Name, Person_Last_Name" {
        It "Organization > Account > Communication > Contact" {

        }

        It "Organization > Account > Site > Communication > Contact" {

        }
    }
}