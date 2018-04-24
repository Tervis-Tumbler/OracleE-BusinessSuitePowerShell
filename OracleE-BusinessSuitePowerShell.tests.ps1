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

function New-FindCustomerAccountNumberTestSet {
    param (
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$SearchLevel,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$PhoneAreaCode,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$PhoneNumber,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$EmailAddress,
        [Parameter(ValueFromPipelineByPropertyName)]$AccountNumber
    )
    process {
        Context "$SearchLevel Search via Phone Number and Email Address" {
            $BadPhoneAreaCode = "000"
            $BadPhoneNumber = "555-0000"
            $BadEmailAddress = "org@0000.com"

            It "$SearchLevel > Phone Number" {
                $CustomerAccountNumber = Find-CustomerAccountNumber -Phone_Area_Code $PhoneAreaCode -Phone_Number $PhoneNumber
                $CustomerAccountNumber | Should -Be $AccountNumber
            }

            It "$SearchLevel > Email Address" {
                $CustomerAccountNumber = Find-CustomerAccountNumber -Email_Address $EmailAddress
                $CustomerAccountNumber | Should -Be $AccountNumber
            }

            It "$SearchLevel > Phone number and Email Address" {
                $CustomerAccountNumber = Find-CustomerAccountNumber -Phone_Area_Code $PhoneAreaCode -Phone_Number $PhoneNumber -Email_Address $EmailAddress
                $CustomerAccountNumber | Should -Be $AccountNumber
            }
        }
    }
}

Describe "OracleE-BusinessSuitePowerShell Find-CustomerAccountNumber" {

    $TestScenarios = @{
        SearchLevel = "Organization > Communication"
        PhoneAreaCode = "941"
        PhoneNumber = "555-1111"
        EmailAddress = "org@25496989.com"
        AccountNumber = 25496989
    },
    @{
        SearchLevel = "Organization > Party Relationships [Person] > Communication"
        PhoneAreaCode = "941"
        PhoneNumber = "555-2222"
        EmailAddress = "2222@25496989.com"
        AccountNumber = 25496989
    },
    @{
        SearchLevel = "Organization > Account > Communication > Contact"
        PhoneAreaCode = "941"
        PhoneNumber = "555-3333"
        EmailAddress = "3333@25496989.com"
        AccountNumber = 25496989
    },
    @{
        SearchLevel = "Organization > Account > Site > Communication > Contact"
        PhoneAreaCode = "941"
        PhoneNumber = "555-4444"
        EmailAddress = "4444@25496989.com"
        AccountNumber = 25496989
    },
    @{
        SearchLevel = "Organization > Account > Site > Communication"
        PhoneAreaCode = "941"
        PhoneNumber = "555-5555"
        EmailAddress = "5555@25496989.com"
        AccountNumber = 25496989
    },
    @{
        SearchLevel = "Bad info that shouldn't return account number"
        PhoneAreaCode = "000"
        PhoneNumber = "555-0000"
        EmailAddress = "org@0000.com"
        AccountNumber = $null
    }

    foreach ($TestScenario in $TestScenarios) {
        New-FindCustomerAccountNumberTestSet @TestScenario
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

