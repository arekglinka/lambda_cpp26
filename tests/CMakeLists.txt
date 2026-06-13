cmake_minimum_required(VERSION 3.25)
project(lambda_cpp26_consumer_test LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 26)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(lambda_cpp26 REQUIRED)

add_executable(consumer_test
    test_consumer.cpp
)
target_link_libraries(consumer_test PRIVATE lambda_cpp26)
