SELECT lookup_code
FROM ar_lookups
WHERE lookup_type like 'CUSTOMER CLASS'
AND (UPPER(:CustomerClass) = UPPER(MEANING) or UPPER(:CustomerClass) = UPPER(LOOKUP_CODE))
AND sysdate between NVL(start_date_active,sysdate) and NVL(end_date_active,sysdate);

