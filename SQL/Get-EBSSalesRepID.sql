SELECT ra.salesrep_id--UPPER(res.source_first_name)||' '||UPPER(res.source_last_name)--salesrep_name
  FROM apps.jtf_rs_resource_extns_vl res, apps.ra_salesreps_all ra
 WHERE UPPER(ra.name) = UPPER(:SalesRepName)
 --UPPER(res.source_first_name)||' '||UPPER(res.source_last_name) = UPPER(p_salesrep)
   AND res.resource_id = ra.resource_id;
   
   
   
   select * FROM apps.jtf_rs_resource_extns_vl res where resource_id = '100007072' ;    --res
   
   select * from apps.ra_salesreps_all ra where resource_id = '100007072' ;             --ra