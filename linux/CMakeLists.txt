cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "file_drop")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.10...3.25)

set(PLUGIN_NAME "file_drop_plugin")

list(APPEND PLUGIN_SOURCES
  "file_drop_plugin.cc"
)

add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

set(file_drop_bundled_libraries
  ""
  PARENT_SCOPE
)

