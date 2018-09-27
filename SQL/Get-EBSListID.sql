SELECT list_header_id AS "List ID"
 FROM qp_list_headers_all
 WHERE name = :ListName
   AND sysdate between NVL(start_date_active,sysdate) and NVL(end_date_active,sysdate)
   AND list_type_code = :ListType;
