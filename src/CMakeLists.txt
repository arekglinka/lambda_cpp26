cmake_minimum_required(VERSION 3.25)
project(lambda_cpp26 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 26)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --- Static library target ---
add_library(${PROJECT_NAME} STATIC
    lambda_cpp26/api.cpp
)

target_include_directories(${PROJECT_NAME}
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
        $<INSTALL_INTERFACE:include>
)

# Conan deps — CMakeToolchain sets CMAKE_PREFIX_PATH to include generators dir
find_package(Arrow REQUIRED CONFIG)
find_package(QuantLib REQUIRED CONFIG)
find_package(Boost REQUIRED)

target_link_libraries(${PROJECT_NAME}
    PUBLIC
        Arrow::arrow_static
        Arrow::parquet_static
        Arrow::arrow_bundled_dependencies
        QuantLib::QuantLib
        Boost::boost
    PRIVATE
        pthread
        dl
        rt
        m
)

# --- Sample Lambda handler binary ---
find_package(aws-lambda-runtime REQUIRED)

add_executable(lambda_handler
    handler.cpp
)
target_link_libraries(lambda_handler
    PRIVATE
        ${PROJECT_NAME}
        aws-lambda-runtime::aws-lambda-runtime
        pthread
        dl
        rt
        m
)

# --- Install ---
include(GNUInstallDirs)

install(TARGETS ${PROJECT_NAME}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
)

install(TARGETS lambda_handler
    RUNTIME DESTINATION bin
)

install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/lambda_cpp26/
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/lambda_cpp26
    FILES_MATCHING PATTERN "*.hpp"
)
