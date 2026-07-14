cmake_minimum_required(VERSION 3.22)
project(cloak CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_compile_options(-Wall -Wextra -fvisibility=hidden -ffunction-sections -fdata-sections)
add_link_options(-Wl,--gc-sections -Wl,--exclude-libs,ALL)

# Small, self-contained .so
set(CMAKE_CXX_FLAGS_RELEASE "-Os -DNDEBUG")

add_library(cloak SHARED
    main.cpp
    config.cpp
    hooks.cpp)

# STL is linked statically via -DANDROID_STL=c++_static (see scripts/build.sh),
# so the module has no runtime dependency on the app's STL.
target_link_libraries(cloak log)
