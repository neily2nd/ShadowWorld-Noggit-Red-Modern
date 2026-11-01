if(BUILD_TESTING)
  find_package(Catch2 2.3.0 QUIET)

  if(NOT Catch2_FOUND)
    add_subdirectory(Catch2)
  endif()
endif()

## Use CMake's standard find_package command. Defining a local wrapper here
## conflicts with toolchain package-discovery wrappers such as vcpkg's.
