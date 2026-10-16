cmake_minimum_required(VERSION 3.16)
project(LibronXCompression LANGUAGES C)

# This builds only the reusable C compression boundary, without Swift/AppKit.
find_package(ZLIB 1.2.9 REQUIRED)
add_library(libronx_compression STATIC
    Sources/CLibronxCompression/wrapper.c
    Sources/CLibronxCompression/blast.c)
target_include_directories(libronx_compression PUBLIC
    Sources/CLibronxCompression/include)
target_compile_features(libronx_compression PUBLIC c_std_99)
target_link_libraries(libronx_compression PUBLIC ZLIB::ZLIB)
if(NOT WIN32)
    find_package(Threads REQUIRED)
    target_link_libraries(libronx_compression PUBLIC Threads::Threads)
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(compression_contract Tests/CompressionContract/compression_contract.c)
    target_link_libraries(compression_contract PRIVATE libronx_compression)
    add_test(NAME compression_contract COMMAND compression_contract)
    set_tests_properties(compression_contract PROPERTIES TIMEOUT 60)
endif()
