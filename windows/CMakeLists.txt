cmake_minimum_required(VERSION 3.14)
project(mssql_plugin LANGUAGES CXX)

set(PROJECT_NAME "mssql_plugin")

add_library(${PROJECT_NAME} SHARED
  "mssql_connection_plugin.cpp"
)

target_compile_definitions(${PROJECT_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PROJECT_NAME} PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PROJECT_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
)

# Bundle the FreeTDS and OpenSSL DLLs with the plugin for Flutter Windows build system
set(mssql_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/bin/sybdb.dll"
  PARENT_SCOPE
)
