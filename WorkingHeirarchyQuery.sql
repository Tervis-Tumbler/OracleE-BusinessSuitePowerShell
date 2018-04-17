DECLARE
    -- Declarations
    var_p_hierarchy_type VARCHAR2(32767) := 'CONTACT';
    var_p_child_id NUMBER := '42924332';
    var_p_child_table_name VARCHAR2(32767) := 'HZ_PARTIES';
    var_p_child_object_type VARCHAR2(32767) := 'PERSON';
    var_p_parent_table_name VARCHAR2(32767) := 'HZ_PARTIES';
    var_p_parent_object_type VARCHAR2(32767) := 'ORGANIZATION';
    var_x_related_nodes_list apps.hz_hierarchy_v2pub.related_nodes_list_type;
    var_x_return_status VARCHAR2(32767);
    var_x_msg_count NUMBER := 0;
    var_x_msg_data VARCHAR2(32767);
BEGIN
    --clear error message stack
    --fnd_msg_pub.delete_msg;
    -- Initialization
--    var_p_hierarchy_type := NULL;
--    var_p_child_id := NULL;
--    var_p_child_table_name := NULL;
--    var_p_child_object_type := NULL;
--    var_p_parent_table_name := NULL;
--    var_p_parent_object_type := NULL;
    -- Call
    apps.hz_hierarchy_v2pub.get_parent_nodes(p_hierarchy_type => var_p_hierarchy_type
                                            ,p_child_id => var_p_child_id
                                            ,p_child_table_name => var_p_child_table_name
                                            ,p_child_object_type => var_p_child_object_type
                                            ,p_parent_table_name => var_p_parent_table_name
                                            ,p_parent_object_type => var_p_parent_object_type
                                            ,x_related_nodes_list => var_x_related_nodes_list
                                            ,x_return_status => var_x_return_status
                                            ,x_msg_count => var_x_msg_count
                                            ,x_msg_data => var_x_msg_data);
    --select var_x_msg_count from dual;
    --this will display your errors
    IF var_x_msg_count > 0
    THEN
        FOR i IN 1 .. var_x_msg_count LOOP
            DBMS_OUTPUT.put_line(   i
                                 || '. '
                                 || SUBSTR(fnd_msg_pub.get(p_encoded => fnd_api.g_false)
                                          ,1
                                          ,255));
        END LOOP;
    END IF;
    IF var_x_related_nodes_list.COUNT > 0
    THEN
        FOR i IN 1 .. var_x_related_nodes_list.COUNT LOOP
            DBMS_OUTPUT.put_line('var_x_related_nodes_list.top_parent_flag: ' || var_x_related_nodes_list(i).top_parent_flag);
        END LOOP;
    END IF;
    -- Transaction Control
    COMMIT;
    DBMS_OUTPUT.put_line('var_x_return_status: ' || var_x_return_status);
    DBMS_OUTPUT.put_line('var_x_msg_count: ' || var_x_msg_count);
    DBMS_OUTPUT.put_line('var_x_msg_data: ' || var_x_msg_data);
--dbms_output.put_line('var_x_related_nodes_list.top_parent_flag: ' || var_x_related_nodes_list.top_parent_flag);
END;