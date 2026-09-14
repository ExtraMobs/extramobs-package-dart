Pod::Spec.new do |s|
  s.name = 'sql_server_wrapper'
  s.version = '0.0.1'
  s.summary = 'SQL Server through bundled FreeTDS and verified TLS.'
  s.description = s.summary
  s.homepage = 'https://github.com/ExtraMobs/mssql_connection'
  s.license = { :file => '../LICENSE' }
  s.author = { 'sql_server_wrapper contributors' => 'https://github.com/ExtraMobs/mssql_connection' }
  s.source = { :path => '.' }
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.vendored_frameworks = 'FreeTDS/FreeTDS-DB.xcframework'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  # FFI symbols have no static callers: retain them in the final executable.
  symbols = %w[sql_server_wrapper_init dbinit dblogin dbloginfree dbsetlname tdsdbopen
    dbclose dbexit dbcmd dbsqlexec dbresults dbnextrow dbnumcols dbcolname dbcoltype
    dbdatlen dbdata dbcount dbsetlogintime dbsettime dbuse dbsetlbool dbsetopt
    dbrpcinit dbrpcparam dbrpcsend dbsqlok dberrhandle dbmsghandle bcp_init bcp_bind
    bcp_sendrow bcp_batch bcp_done bcp_collen bcp_colptr dbconvert]
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '$(inherited) ' + symbols.map { |name| "-Wl,-u,_#{name}" }.join(' ') }
end
