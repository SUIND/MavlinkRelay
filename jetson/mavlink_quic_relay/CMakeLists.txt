cmake_minimum_required(VERSION 3.10)
project(mavlink_quic_relay)

# ── C++ Standard ───────────────────────────────────────────────────────────────
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ── Compile flags ──────────────────────────────────────────────────────────────
add_compile_options(-Wall -Wextra -Werror)

# ── ROS / catkin ───────────────────────────────────────────────────────────────
find_package(catkin REQUIRED COMPONENTS
  roscpp
  mavros_msgs
  std_msgs
)

# ── msquic library detection ───────────────────────────────────────────────────
# Step 1: Try system install locations
find_library(MSQUIC_LIB msquic
  PATHS /usr/local/lib /usr/lib
  NO_DEFAULT_PATH
)

# Step 2: If not found yet and MSQUIC_ROOT is provided, try there
if(NOT MSQUIC_LIB AND DEFINED MSQUIC_ROOT)
  find_library(MSQUIC_LIB msquic
    PATHS "${MSQUIC_ROOT}/lib"
    NO_DEFAULT_PATH
  )
endif()

# Step 3: Determine include path for msquic headers
if(MSQUIC_LIB)
  # Derive include dir from MSQUIC_ROOT if given, otherwise use system default
  if(DEFINED MSQUIC_ROOT)
    set(MSQUIC_INCLUDE_DIR "${MSQUIC_ROOT}/include")
  else()
    set(MSQUIC_INCLUDE_DIR "/usr/local/include")
  endif()
  message(STATUS "msquic found: ${MSQUIC_LIB}")
  message(STATUS "msquic include: ${MSQUIC_INCLUDE_DIR}")
  set(MSQUIC_FOUND TRUE)
else()
  message(WARNING
    "msquic not found — mavlink_quic_relay node will not link until msquic is installed. "
    "Build the package structure with -DMSQUIC_ROOT=<path> or install msquic to /usr/local. "
    "See README.md for ARM64 build-from-source instructions."
  )
  set(MSQUIC_FOUND FALSE)
  set(MSQUIC_INCLUDE_DIR "")
endif()

# ── catkin package declaration ─────────────────────────────────────────────────
catkin_package(
  INCLUDE_DIRS include
  CATKIN_DEPENDS roscpp mavros_msgs std_msgs
)

# ── Include directories ────────────────────────────────────────────────────────
include_directories(
  include
  ${catkin_INCLUDE_DIRS}
)

if(MSQUIC_FOUND)
  include_directories(${MSQUIC_INCLUDE_DIR})
endif()

# ── Executable ────────────────────────────────────────────────────────────────
if(MSQUIC_FOUND)
  add_executable(${PROJECT_NAME}_node
    src/main.cpp
    src/relay_node.cpp
    src/quic_client.cpp
    src/ros_interface.cpp
    src/priority_classifier.cpp
    src/reconnect_manager.cpp
  )

  target_link_libraries(${PROJECT_NAME}_node
    ${catkin_LIBRARIES}
    ${MSQUIC_LIB}
  )

  add_dependencies(${PROJECT_NAME}_node
    ${${PROJECT_NAME}_EXPORTED_TARGETS}
    ${catkin_EXPORTED_TARGETS}
  )

  # ── Install ─────────────────────────────────────────────────────────────────
  install(TARGETS ${PROJECT_NAME}_node
    RUNTIME DESTINATION ${CATKIN_PACKAGE_BIN_DESTINATION}
  )
else()
  # msquic not available — build object library so catkin can still parse the package
  # This lets `catkin build` succeed for package structure scaffolding.
  message(STATUS "Skipping ${PROJECT_NAME}_node target — msquic not found")
endif()

# Install headers (for downstream packages that might include our headers)
install(DIRECTORY include/${PROJECT_NAME}/
  DESTINATION ${CATKIN_PACKAGE_INCLUDE_DESTINATION}
  FILES_MATCHING PATTERN "*.h" PATTERN "*.hpp"
  PATTERN ".gitkeep" EXCLUDE
)

# ── Tests ─────────────────────────────────────────────────────────────────────
if(CATKIN_ENABLE_TESTING)
  find_package(rostest REQUIRED)

  catkin_add_gtest(test_priority_classifier
    test/test_priority_classifier.cpp
    src/priority_classifier.cpp
  )
  target_include_directories(test_priority_classifier PRIVATE include)

  catkin_add_gtest(test_thread_safe_queue
    test/test_thread_safe_queue.cpp
    src/ros_interface.cpp
  )
  target_include_directories(test_thread_safe_queue PRIVATE include)
  target_link_libraries(test_thread_safe_queue ${catkin_LIBRARIES})

  catkin_add_gtest(test_mavlink_framing
    test/test_mavlink_framing.cpp
  )
  target_include_directories(test_mavlink_framing PRIVATE include)

  catkin_add_gtest(test_ros_interface_framing
    test/test_ros_interface_framing.cpp
  )
  target_include_directories(test_ros_interface_framing PRIVATE include)
  target_link_libraries(test_ros_interface_framing ${catkin_LIBRARIES})

  catkin_add_gtest(test_reconnect_manager
    test/test_reconnect_manager.cpp
    src/reconnect_manager.cpp
    src/ros_interface.cpp
    src/quic_client.cpp
  )
  target_include_directories(test_reconnect_manager PRIVATE include ${MSQUIC_INCLUDE_DIR})
  target_link_libraries(test_reconnect_manager ${catkin_LIBRARIES} ${MSQUIC_LIB})

  add_rostest(test/test_relay_roundtrip.test)

  catkin_install_python(PROGRAMS
    test/mock_quic_server.py
    test/test_relay_roundtrip.py
    DESTINATION ${CATKIN_PACKAGE_BIN_DESTINATION}
  )
endif()
