//+build freebsd, openbsd, netbsd
//+private
package mem_virtual

_reserve :: proc "contextless" (size: uint) -> (data: []byte, err: Allocator_Error) {
	return nil, nil
}

_commit :: proc "contextless" (data: rawptr, size: uint) -> Allocator_Error {
	return nil
}

_decommit :: proc "contextless" (data: rawptr, size: uint) {
}

_release :: proc "contextless" (data: rawptr, size: uint) {
}

_protect :: proc "contextless" (data: rawptr, size: uint, flags: Protect_Flags) -> bool {
	return false
}

_platform_memory_init :: proc() {
}

_map_file :: proc "contextless" (fd: uintptr, size: i64, flags: Map_File_Flags) -> (data: []byte, error: Map_File_Error) {
	return nil, .Map_Failure
}

/* TODO */
_Page_Allocator_Platform_Data :: uintptr

_page_allocator_aligned_alloc :: proc(size, alignment: int, flags: Page_Allocator_Flags) -> ([]byte, Allocator_Error) {
	return nil, .Mode_Not_Implemented
}

_page_allocator_aligned_resize :: proc(old_ptr: rawptr,
				       old_size, new_size, new_align: int,
				       flags: Page_Allocator_Flags) -> ([]byte, Allocator_Error) {
	return nil, .Mode_Not_Implemented
}

_page_allocator_free :: proc(p: rawptr, size: int) -> Allocator_Error { return .Mode_Not_Implemented }

_set_system_large_page_count :: proc(count: int) -> (okay: bool) { return false }
