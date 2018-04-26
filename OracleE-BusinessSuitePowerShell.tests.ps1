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

#https://stackoverflow.com/questions/28331257/unique-combos-from-powershell-array-no-duplicate-combos?utm_medium=organic&utm_source=google_rich_qa&utm_campaign=google_rich_qa
function Get-Subsets ($a){
    #uncomment following to ensure only unique inputs are parsed
    #e.g. 'B','C','D','E','E' would become 'B','C','D','E'
    #$a = $a | Select-Object -Unique
    #create an array to store output
    $l = @()
    #for any set of length n the maximum number of subsets is 2^n
    for ($i = 0; $i -lt [Math]::Pow(2,$a.Length); $i++)
    { 
        #temporary array to hold output
        [string[]]$out = New-Object string[] $a.length
        #iterate through each element
        for ($j = 0; $j -lt $a.Length; $j++)
        { 
            #start at the end of the array take elements, work your way towards the front
            if (($i -band (1 -shl ($a.Length - $j - 1))) -ne 0)
            {
                #store the subset in a temp array
                $out[$j] = $a[$j]
            }
        }
        #stick subset into an array
        $l += -join $out
    }
    #group the subsets by length, iterate through them and sort
    $l | Group-Object -Property Length | %{$_.Group | sort}
}

function New-FindCustomerAccountNumberByEmailAndPhoneNumberTestSet {
    param (
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$SearchLevel,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$PhoneAreaCode,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$PhoneNumber,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$EmailAddress,
        [Parameter(ValueFromPipelineByPropertyName)]$AccountNumber
    )
    process {
        Context "$SearchLevel Search via Phone Number and Email Address" {
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

function New-FindCustomerAccountNumberByLocationTestSet {
    param (
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$SearchLevel,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$Address1,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$Postal_Code,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$State,
        [Parameter(ValueFromPipelineByPropertyName)]$AccountNumber
    )
    process {
        $ParameterHashTable = $PSBoundParameters | ConvertFrom-PSBoundParameters -ExcludeProperty SearchLevel,AccountNumber -AsHashTable
        $Parameters = $ParameterHashTable | Split-HashTable
        Context "$SearchLevel Search via Address1, Postal_Code, and State" {
            New-ItCondition -SearchLevel $SearchLevel -AccountNumber $AccountNumber @ParameterHashTable

            foreach ($Parameter in $Parameters ) {
                New-ItCondition -SearchLevel $SearchLevel -AccountNumber $AccountNumber @Parameter
            }
        }
    }
}

function New-ItCondition {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$SearchLevel,
        [Parameter(ValueFromPipelineByPropertyName)]$Address1,
        [Parameter(ValueFromPipelineByPropertyName)]$Postal_Code,
        [Parameter(ValueFromPipelineByPropertyName)]$State,
        [Parameter(ValueFromPipelineByPropertyName)]$AccountNumber
    )
    begin {
        $ParameterHashTable = $PSBoundParameters | ConvertFrom-PSBoundParameters -ExcludeProperty SearchLevel,AccountNumber -AsHashTable
    }
    process {
        It "$SearchLevel > $($ParameterHashTable.Keys -join ", ")" {
            $CustomerAccountNumber = Find-CustomerAccountNumber @ParameterHashTable
            $CustomerAccountNumber | Should -Be $AccountNumber
        }
    }
}

Describe "OracleE-BusinessSuitePowerShell Find-CustomerAccountNumber" {

    $EmailAndPhoneNumberTestScenarios = @{
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

    foreach ($TestScenario in $EmailAndPhoneNumberTestScenarios) {
        New-FindCustomerAccountNumberByEmailAndPhoneNumberTestSet @TestScenario
    }
}
Describe "OracleE-BusinessSuitePowerShell Find-CustomerAccountNumber Location" {
    $LocationTestScenarios = @{
        SearchLevel = "Organization > Account > Communication > Contact > Contact Addresses > Location"
        Address1 = "Org > Acct > Com > Contact Address1"
        Postal_Code = "99996"
        State = "AP"
        AccountNumber = 25496989
    },
    @{
        SearchLevel = "Organization > Account > Site > Communication > Contact > Colntact Addresses > Location"
        Address1 = "Organization > Account > Site > Communication > Contact First_Name Address1"
        Postal_Code = "99997"
        State = "AE"
        AccountNumber = 25496989
    },
    @{
        SearchLevel = "Organization > Account > Site > Location"
        Address1 = "Organization Site Address1"
        Postal_Code = "99998"
        State = "AA"
        AccountNumber = 25496989
    }

    foreach ($TestScenario in $LocationTestScenarios) {
        New-FindCustomerAccountNumberByLocationTestSet @TestScenario
    }
    
    Context "Search via Person_First_Name, Person_Last_Name" {
        It "Organization > Account > Communication > Contact" {

        }

        It "Organization > Account > Site > Communication > Contact" {

        }
    }
}

