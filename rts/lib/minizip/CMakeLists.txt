# Spring supplied CMake build file

set(MINIZIP_FIND_QUIETLY TRUE)
FIND_PACKAGE_STATIC(MiniZip)

if     (MINIZIP_FOUND)
	# Use the system supplied MiniZip library
	message(STATUS "Using minizip library: ${MINIZIP_LIBRARY}")

	set_global(SPRING_MINIZIP_INCLUDE_DIR "${MINIZIP_INCLUDE_DIR}")
	set_global(SPRING_MINIZIP_LIBRARY "${MINIZIP_LIBRARY}")
	# A static minizip-ng (the spring-static-libs build) depends on liblzma. Linux
	# gets liblzma through the libunwind block in rts/CMakeLists.txt and tolerates
	# unresolved symbols in shared objects; macOS does neither, so unitsync failed
	# to link. Carry the dependency with the library on APPLE only.
	if (APPLE AND MINIZIP_LIBRARY MATCHES "\\.a$")
		find_library(MINIZIP_LZMA_LIBRARY NAMES liblzma.a lzma)
		if (MINIZIP_LZMA_LIBRARY)
			set_global(SPRING_MINIZIP_LIBRARY "${MINIZIP_LIBRARY};${MINIZIP_LZMA_LIBRARY}")
		endif ()
	endif ()
else   (MINIZIP_FOUND)
	# Build our own minizip library
	
	set(miniZipSources
			"unzip.c"
			"zip.c"
			"ioapi.c"
		)

	add_definitions(-DNOCRYPT -DNOUNCRYPT)
	find_package(ZLIB 1.2.7 REQUIRED)

	add_library(minizip STATIC EXCLUDE_FROM_ALL ${miniZipSources})
	target_link_libraries(minizip ZLIB::ZLIB)
	set_target_properties(minizip PROPERTIES COMPILE_FLAGS "${PIC_FLAG}")

	set_global(SPRING_MINIZIP_INCLUDE_DIR "${CMAKE_SOURCE_DIR}/rts/lib")
	set_global(SPRING_MINIZIP_LIBRARY minizip)
endif  (MINIZIP_FOUND)
