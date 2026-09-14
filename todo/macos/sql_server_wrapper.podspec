Pod::Spec.new do |s|
  s.name = 'sql_server_wrapper'
  s.version = '0.0.1'
  s.summary = 'SQL Server through bundled FreeTDS and verified TLS.'
  s.description = s.summary
  s.homepage = 'https://github.com/ExtraMobs/mssql_connection'
  s.license = { :file => '../LICENSE' }
  s.author = { 'sql_server_wrapper contributors' => 'https://github.com/ExtraMobs/mssql_connection' }
  s.source = { :path => '.' }
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.vendored_libraries = 'Libraries/lib/libsybdb.dylib'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
