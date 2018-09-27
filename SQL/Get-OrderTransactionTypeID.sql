SELECT t.transaction_type_id  
  FROM oe_transaction_types_all t,oe_transaction_types_tl tl
 WHERE t.transaction_type_code  = 'ORDER' 
   AND t.transaction_type_id = tl.transaction_type_id
   AND tl.language = userenv('LANG')
   and UPPER(tl.name) = :OrderTransactionType;