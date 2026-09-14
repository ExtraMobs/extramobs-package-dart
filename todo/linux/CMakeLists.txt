cmake_minimum_required(VERSION 3.14)
project(sql_server_wrapper LANGUAGES C)
set(sql_server_wrapper_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/lib/libsybdb.so"
  PARENT_SCOPE
)
