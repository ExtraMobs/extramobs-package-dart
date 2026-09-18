cmake_minimum_required(VERSION 3.14)
project(mssql LANGUAGES C)
set(mssql_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/lib/libsybdb.so"
  PARENT_SCOPE
)
