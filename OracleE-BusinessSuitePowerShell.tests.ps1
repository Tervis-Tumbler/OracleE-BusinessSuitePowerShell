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
    Context "Search via Phone Number and Email Address" {
        It "Organization > Communication > Phone Number" {
            $AccountNumber = Find-CustomerAccountNumber -Phone_Area_Code 941 -Phone_Number 555-1111
            $AccountNumber | Should -Be 25496989
        }

        It "Organization > Communication > Phone Number that doesn't exist" {
            $AccountNumber = Find-CustomerAccountNumber -Phone_Area_Code 941 -Phone_Number 555-0000
            $AccountNumber | Should -BeNullOrEmpty
        }
        
        It "Organization > Communication > Email Address" {
            $AccountNumber = Find-CustomerAccountNumber -Email_Address "org@25496989.com"
            $AccountNumber | Should -Be 25496989
        }

        It "Organization > Communication > Email Address that doesn't exist" {
            $AccountNumber = Find-CustomerAccountNumber -Email_Address "org@0000.com"
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