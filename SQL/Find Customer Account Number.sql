WITH 
FilteredContactPoints AS (
    SELECT *
    FROM hz_contact_points ContactPoints
    WHERE (
        UPPER(ContactPoints.email_address) = UPPER(:Email_Address)
        AND ContactPoints.Phone_Area_Code = :Phone_Area_Code
        AND ContactPoints.Phone_Number = :Phone_Number
    ) OR (
        :Email_Address IS NULL
        AND ContactPoints.Phone_Area_Code = :Phone_Area_Code
        AND ContactPoints.Phone_Number = :Phone_Number
    ) OR (
        UPPER(ContactPoints.email_address) = UPPER(:Email_Address)
        AND :Phone_Area_Code IS NULL
        AND ContactPoints.Phone_Number = :Phone_Number
    ) OR (
        :Email_Address IS NULL
        AND :Phone_Area_Code IS NULL
        AND ContactPoints.Phone_Number = :Phone_Number
    ) OR (
        UPPER(ContactPoints.email_address) = UPPER(:Email_Address)
        AND ContactPoints.Phone_Area_Code = :Phone_Area_Code
        AND :Phone_Number IS NULL
    ) OR (
        :Email_Address IS NULL
        AND ContactPoints.Phone_Area_Code = :Phone_Area_Code
        AND :Phone_Number IS NULL
    ) OR (
        UPPER(ContactPoints.email_address) = UPPER(:Email_Address)
        AND :Phone_Area_Code IS NULL
        AND :Phone_Number IS NULL
    )
),
FilteredLocations AS (
    SELECT * 
    FROM apps.hz_locations Locations
    WHERE (
        Locations.ADDRESS1 = :Address1
        AND Locations.POSTAL_CODE = :Postal_Code
        AND Locations.State = :State
    ) OR (
        :Address1 IS NULL
        AND Locations.POSTAL_CODE = :Postal_Code
        AND Locations.State = :State        
    ) OR (
        Locations.ADDRESS1 = :Address1
        AND :Postal_Code IS NULL
        AND Locations.State = :State
    ) OR (
        :Address1 IS NULL
        AND :Postal_Code IS NULL
        AND Locations.State = :State        
    ) OR  (
        Locations.ADDRESS1 = :Address1
        AND Locations.POSTAL_CODE = :Postal_Code
        AND :State IS NULL
    ) OR (
        :Address1 IS NULL
        AND Locations.POSTAL_CODE = :Postal_Code
        AND :State IS NULL
    ) OR (
        Locations.ADDRESS1 = :Address1
        AND :Postal_Code IS NULL
        AND :State IS NULL
    )
),
FilteredParties AS (
    SELECT * 
    FROM apps.hz_parties Parties
    WHERE (
        Parties.PERSON_FIRST_NAME = :Person_First_Name
        AND Parties.PERSON_LAST_NAME = :Person_Last_Name
    ) OR (
        :Person_First_Name IS NULL
        AND Parties.PERSON_LAST_NAME = :Person_Last_Name        
    ) OR (
        Parties.PERSON_FIRST_NAME = :Person_First_Name
        AND :Person_Last_Name IS NULL
    )
),
OrganizationParty AS (
    SELECT /*+ INLINE */ *
    FROM apps.hz_parties 
    WHERE 1 = 1
    AND apps.hz_parties.party_type = 'ORGANIZATION'
    AND apps.hz_parties.status = 'A'
),
-- Search via Phone Number and Email Address
AcctNumFromContactPoint AS (
    (
        -- Organization > Account > Site > Communication
        SELECT Distinct CustomerAccount.Account_Number
        FROM OrganizationParty
        JOIN apps.hz_cust_accounts_all CustomerAccount 
        ON OrganizationParty.party_id = CustomerAccount.party_id
        JOIN HZ_PARTY_SITES OrganizationSite
        ON OrganizationParty.party_id = OrganizationSite.party_id
            JOIN FilteredContactPoints OrganizationSiteContactPoints
            ON OrganizationSite.party_site_id = OrganizationSiteContactPoints.OWNER_TABLE_ID
    )
    UNION
    (
        -- Organization > Communication
        SELECT Distinct CustomerAccount.Account_Number
        FROM OrganizationParty
        JOIN apps.hz_cust_accounts_all CustomerAccount  ON OrganizationParty.party_id = CustomerAccount.party_id
        JOIN FilteredContactPoints OrganizationContactPoints
          ON OrganizationParty.party_id = OrganizationContactPoints.OWNER_TABLE_ID
    )
    UNION
    (
        -- Organization > Party Relationships [Person] > Communication
        SELECT Distinct CustomerAccount.Account_Number
        FROM OrganizationParty
        JOIN apps.hz_cust_accounts_all CustomerAccount 
        ON OrganizationParty.party_id = CustomerAccount.party_id
        JOIN apps.hz_relationships PartyRelationship
        ON OrganizationParty.party_id = PartyRelationship.object_id
            JOIN apps.hz_parties OrgPartyRelationshipParty --OrganizationPartyRelationshipParty
            ON PartyRelationship.subject_id = OrgPartyRelationshipParty.party_id
                JOIN FilteredContactPoints OrgPartyRelPartyContactPoint --OrganizationPartyRelationshipPartyContactPoint
                ON OrgPartyRelationshipParty.party_id = OrgPartyRelPartyContactPoint.OWNER_TABLE_ID
    )
    UNION
    (
        -- Organization > Account > Communication > Contact
        -- Would have to do something to exclude contacts with site Ids to not get the following as well
        -- Organization > Account > Site > Communication > Contact 
        SELECT Distinct CustomerAccount.Account_Number
        FROM OrganizationParty
        JOIN apps.hz_cust_accounts_all CustomerAccount  ON OrganizationParty.party_id = CustomerAccount.party_id
        JOIN apps.hz_relationships PartyRelationship
          ON OrganizationParty.party_id = PartyRelationship.object_id
            JOIN apps.hz_parties OrgContPartyRelationshipParty --OrganizationContactPartyRelationshipParty
              ON PartyRelationship.party_id = OrgContPartyRelationshipParty.party_id
                JOIN FilteredContactPoints OrgContPartRelPartyContPoint --OrganizationContactPartyRelationshipPartyContactPoint
                  ON OrgContPartyRelationshipParty.party_id = OrgContPartRelPartyContPoint.OWNER_TABLE_ID
    )
),
-- Address1, Postal_Code, City
AccountNumberFromLocations AS (
    (        
        -- Organization > Account > Site > Location
        SELECT Distinct CustomerAccount.Account_Number
        FROM OrganizationParty
        JOIN apps.hz_cust_accounts_all CustomerAccount  ON OrganizationParty.party_id = CustomerAccount.party_id
        JOIN HZ_PARTY_SITES OrganizationSite
        ON OrganizationParty.party_id = OrganizationSite.party_id
            JOIN FilteredLocations OrganizationSiteLocation
            ON OrganizationSite.location_id = OrganizationSiteLocation.location_id
    )
    UNION
    (
        -- Organization > Account > Communication > Contact > Contact Addresses > Location 
        -- Organization > Account > Site > Communication > Contact > Colntact Addresses > Location
        SELECT Distinct CustomerAccount.Account_Number
        FROM OrganizationParty
        JOIN apps.hz_cust_accounts_all CustomerAccount 
        ON OrganizationParty.party_id = CustomerAccount.party_id
        JOIN apps.hz_relationships PartyRelationship
        ON OrganizationParty.party_id = PartyRelationship.object_id
            JOIN apps.hz_parties OrgContPartyRelationshipParty --OrganizationContactPartyRelationshipParty
            ON PartyRelationship.party_id = OrgContPartyRelationshipParty.party_id
                JOIN HZ_PARTY_SITES OrganizationSite
                ON OrgContPartyRelationshipParty.party_id = OrganizationSite.party_id
                    JOIN FilteredLocations OrganizationSiteLocation
                    ON OrganizationSite.location_id = OrganizationSiteLocation.location_id
    )
),
-- Search via Person_First_Name, Person_Last_Name
AccountNumberPersonName AS (
        -- Organization > Account > Communication > Contact
        -- Organization > Account > Site > Communication > Contact
        SELECT Distinct CustomerAccount.Account_Number
        FROM OrganizationParty
        JOIN apps.hz_cust_accounts_all CustomerAccount  ON OrganizationParty.party_id = CustomerAccount.party_id
        JOIN apps.hz_relationships PartyRelationship
          ON OrganizationParty.party_id = PartyRelationship.object_id
            JOIN FilteredParties OrganizationContactParty --OrganizationContactParty
              ON PartyRelationship.subject_id = OrganizationContactParty.party_id
)



    SELECT *
    FROM  
    AcctNumFromContactPoint
    WHERE Account_Number in (
        Select Account_Number
        FROM AccountNumberFromLocations
        UNION
        Select Account_Number
        FROM AccountNumberPersonName
    ) OR (
        :Address1 IS NULL
        AND :Postal_Code IS NULL
        AND :State IS NULL
        AND :Person_First_Name IS NULL
        AND :Person_Last_Name IS NULL
    )
UNION
    SELECT *
    FROM 
    AccountNumberFromLocations
    WHERE Account_Number in (
        Select Account_Number
        FROM AcctNumFromContactPoint
        UNION
        Select Account_Number
        FROM AccountNumberPersonName
    ) OR (
        :Email_Address IS NULL
        AND :Phone_Area_Code IS NULL
        AND :Phone_Number IS NULL
        AND :Person_First_Name IS NULL
        AND :Person_Last_Name IS NULL
    )
UNION
    SELECT *
    FROM
    AccountNumberPersonName
    WHERE Account_Number in (
        Select Account_Number
        FROM AcctNumFromContactPoint
        UNION
        Select Account_Number
        FROM AccountNumberFromLocations
    ) OR (
        :Email_Address IS NULL
        AND :Phone_Area_Code IS NULL
        AND :Phone_Number IS NULL
        AND :Address1 IS NULL
        AND :Postal_Code IS NULL
        AND :State IS NULL
    )
;